// read-budget/index.js - the opencode 2.x plugin: keep one `read` from eating the window.
//
// Why (docs/roadmap.md -> "Large-file fix (2026-10-17)"): opencode's built-in
// read returns up to 2000 lines / 50 KiB per call, in 1.x and still in 2.3.2.
// Task kane-08 asked qwen3.6 (65,536-token window) to work in two files of
// 131 KB and 185 KB; every cycle it read both whole, the window overflowed,
// opencode compacted, and the same reads came back 17 to 19 times per run until
// the 45-minute timeout: 3 runs of 3, 0 edits.
//
// What it does (the same as the 1.x plugin, ../read-budget.js):
//   1. caps every read at a share of the session's model window:
//      min(51200, floor(contextTokens * 0.08 * 3.3)) chars, about 17,300 at 64k
//      and no clamp at all for a 200k hosted model. It does that by lowering
//      the call's own `limit`, so read's footer ("[Output truncated. Continue
//      reading with offset: N]") stays true;
//   2. appends one line to a clamped result saying why and what to do (grep,
//      then read just those lines);
//   3. gives each file a budget per compaction, floor(contextTokens * 0.25 *
//      3.3) chars served: once it is spent, further reads of that file get a
//      100-line window (SWE-agent's best window, Table 3 of
//      https://arxiv.org/html/2405.15793v3). A read is never refused;
//   4. resets those counters when the session compacts.
// HOMELAB_READ_MAX_CHARS=<n> replaces the computed cap; =off switches the whole
// plugin off (no clamp, no hint). HOMELAB_READ_BUDGET_LOG=<file> appends one
// JSON line per clamp (the harness sets it per run and counts them), and a
// "loaded" line at setup that the harness reads.
//
// The 2.x plugin API, checked on opencode 2.3.2 (2026-11-21) by a probe plugin
// inside `opencode serve` with a scripted model, not only from the docs
// (https://opencode.ai/v2/docs/build/plugins/server):
//   - a configured plugin is a directory; `index.js` is loaded when there is no
//     `server.js`. A plain default export {id, setup(ctx)} loads: Plugin.define
//     from @opencode/plugin is not needed, so the plugin has no dependencies.
//     `serve` (and `--standalone`) run setup in the caller's environment; the
//     shared background service does not.
//   - ctx.tool.hook("execute.before", cb): event {tool, sessionID, agent,
//     messageID, id, input}. input is the decoded call ({path, offset?, limit?};
//     the 1.x `filePath` key is gone), and a mutation of event.input.limit is
//     what read runs with.
//   - ctx.tool.hook("execute.after", cb): event {..., input, status}; on
//     "completed", event.result = {output, content, metadata}, where `content`
//     (an array of {type: "text", text}) is what the model gets. Assigning a
//     new event.result reaches the model.
//   - ctx.session.hook("context", cb): before each model call, event {sessionID,
//     agent, model: {providerID, id}, system, messages, tools, options}. The
//     window is not on it: ctx.model.list() -> {data: [{providerID, id, limit:
//     {context}}]}, which lists the config's own providers only once that
//     location's config has loaded (at setup it may not), so it is read here.
//   - ctx.session.hook("compaction", cb): {sessionID, ...} on every compaction,
//     a manual POST /api/session/{id}/compact included.
//   - read (ReadTool.read, AW): "Read file <path>, lines A-B", then "<n>: <line>"
//     lines, then the footer; offset < 0 counts from the end of the file.
// tests/test-read-budget.ps1 checks this inside the real opencode (the live
// part); any opencode upgrade must re-run it.

import { homedir } from "node:os"
import { isAbsolute, join, resolve } from "node:path"
import {
  DEFAULT_CONTEXT_TOKENS, FRAME_CHARS, LOADED_KEY, MAX_CAP_CHARS, WINDOW_LINES,
  budgetHint, capChars, capHint, fileBudgetChars, fileLogger, fitLines, isOff, keyOf, naturalLines, scanFile,
} from "./core.js"

export * from "./core.js"

// read resolves a relative path against the session's directory, and ~/ to home.
function absolute(directory, path) {
  if (path === "~" || path.startsWith("~/") || path.startsWith("~\\")) return join(homedir(), path.slice(1))
  return isAbsolute(path) ? path : resolve(directory, path)
}

// The model-facing text of a read result: a string, or text parts.
export function resultText(content) {
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return ""
  return content.map((p) => (p && p.type === "text" && typeof p.text === "string" ? p.text : "")).join("")
}

// The same result with `line` appended to its (last) text.
export function withLine(content, line) {
  if (typeof content === "string") return content + "\n" + line
  const parts = Array.isArray(content) ? content : []
  let last = -1
  parts.forEach((p, i) => { if (p && p.type === "text" && typeof p.text === "string") last = i })
  if (last < 0) return [...parts, { type: "text", text: line }]
  return parts.map((p, i) => (i === last ? { ...p, text: p.text + "\n" + line } : p))
}

// The plugin's hooks as plain functions, with state, logger, directory and the
// window lookup injectable for tests. `contextOfModel(model)` resolves a
// {providerID, id} to its limit.context (a number, or undefined).
export function createHooks(
  state = { contexts: new Map(), used: new Map(), pending: new Map(), clamps: 0 },
  log = () => {},
  directory = process.cwd(),
  contextOfModel = async () => undefined,
) {
  if (!state.contexts) state.contexts = new Map()
  if (!state.used) state.used = new Map()
  if (!state.pending) state.pending = new Map()
  const contextOf = (sessionID) => state.contexts.get(sessionID) ?? DEFAULT_CONTEXT_TOKENS
  const usedOf = (sessionID) => {
    if (!state.used.has(sessionID)) state.used.set(sessionID, new Map())
    return state.used.get(sessionID)
  }
  const pendingKey = (event) => `${event.sessionID}\u0000${event.id}`
  return {
    state,
    context: async (event) => {
      if (!event || !event.sessionID || !event.model) return
      // The title and summary calls run a small model in the same session.
      if (event.agent === "title" || event.agent === "summary" || event.agent === "compaction") return
      const tokens = Number(await contextOfModel(event.model))
      if (tokens > 0) state.contexts.set(event.sessionID, tokens)
    },
    before: async (event) => {
      if (isOff() || !event || event.tool !== "read" || !event.input) return
      const input = event.input
      if (typeof input.path !== "string" || input.path === "") return
      // read treats a missing or 0 offset or limit as its default.
      const rawOffset = input.offset === undefined || input.offset === null ? 1 : Number(input.offset)
      const asked = input.limit === undefined || input.limit === null || Number(input.limit) === 0 ? undefined : Number(input.limit)
      if (!Number.isInteger(rawOffset) || (asked !== undefined && !(asked >= 1))) return
      const path = absolute(directory, input.path)
      const scan = scanFile(path, "v2")
      if (!scan || scan.lines.length === 0) return
      // A negative offset starts that many lines from the end.
      const offset = rawOffset === 0 ? 1 : rawOffset < 0 ? Math.max(1, scan.lines.length + 1 + rawOffset) : rawOffset
      // Past the end, read serves the last lines itself (at most 100).
      if (scan.lines.length < offset) return
      const tokens = contextOf(event.sessionID)
      const cap = capChars(tokens)
      const key = keyOf(path)
      const spent = (usedOf(event.sessionID).get(key) || 0) >= fileBudgetChars(tokens)
      const natural = naturalLines(scan.lines, offset, asked)
      // At read's own 50 KB there is nothing to add: its byte cut already applies.
      let target = Math.min(
        asked ?? Infinity,
        cap >= MAX_CAP_CHARS ? Infinity : fitLines(scan.lines, offset, Math.max(1, cap - input.path.length - FRAME_CHARS)),
      )
      if (spent) target = Math.min(target, WINDOW_LINES)
      if (target >= natural) return
      input.limit = target
      const reason = spent ? "budget" : "cap"
      state.pending.set(pendingKey(event), {
        sessionID: event.sessionID, path: input.path, key, offset: rawOffset, asked: asked ?? null, set: target, reason,
        hint: spent ? budgetHint(input.path, usedOf(event.sessionID).get(key) || 0) : capHint(input.path, scan),
      })
    },
    after: async (event) => {
      if (!event || event.tool !== "read") return
      const p = state.pending.get(pendingKey(event))
      if (p) state.pending.delete(pendingKey(event))
      if (event.status !== "completed" || !event.result) return
      const served = resultText(event.result.content).length
      if (event.sessionID && event.input && typeof event.input.path === "string" && event.input.path !== "") {
        const used = usedOf(event.sessionID)
        const key = keyOf(absolute(directory, event.input.path))
        used.set(key, (used.get(key) || 0) + served)
      }
      if (!p) return
      event.result = { ...event.result, content: withLine(event.result.content, p.hint) }
      state.clamps = (state.clamps || 0) + 1
      log("clamp", {
        sessionID: p.sessionID, path: p.path, offset: p.offset, asked: p.asked, set: p.set, reason: p.reason, chars: served,
      })
    },
    // The budget is per compaction: the compacted context no longer holds what
    // was read.
    compaction: async (event) => {
      if (event && event.sessionID) state.used.delete(event.sessionID)
    },
  }
}

// {providerID, id} -> limit.context from ctx.model.list(), cached; a model not
// seen yet re-reads the list (the location's config may have loaded since).
export function modelLookup(model) {
  const cache = new Map()
  return async (m) => {
    const key = `${m.providerID}/${m.id}`
    if (!cache.has(key)) {
      try {
        const listed = await model.list()
        for (const x of (listed && listed.data) || listed || []) {
          const tokens = x && x.limit && Number(x.limit.context)
          if (x && tokens > 0) cache.set(`${x.providerID}/${x.id}`, tokens)
        }
      } catch {
        // an unknown window falls back to 64k
      }
    }
    return cache.get(key)
  }
}

export default {
  id: "homelab-read-budget",
  async setup(ctx) {
    const log = fileLogger(process.env.HOMELAB_READ_BUDGET_LOG)
    const loaded = (globalThis[LOADED_KEY] ??= new Set())
    const dir = (ctx && ctx.location && ctx.location.directory) || ""
    if (loaded.has(dir)) {
      log("duplicate copy skipped", { directory: dir })
      return
    }
    loaded.add(dir)
    const hooks = createHooks(undefined, log, dir || process.cwd(), modelLookup(ctx.model))
    const registrations = [
      await ctx.session.hook("context", hooks.context),
      await ctx.tool.hook("execute.before", hooks.before),
      await ctx.tool.hook("execute.after", hooks.after),
      await ctx.session.hook("compaction", hooks.compaction),
    ]
    log("loaded", { off: isOff(), capOverride: process.env.HOMELAB_READ_MAX_CHARS || null })
    return async () => {
      loaded.delete(dir)
      for (const r of registrations) {
        try {
          if (r && typeof r.dispose === "function") await r.dispose()
        } catch {}
      }
    }
  },
}
