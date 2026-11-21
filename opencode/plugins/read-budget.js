// read-budget.js - an opencode plugin: keep one `read` from eating the window.
//
// Why (docs/roadmap.md -> "Large-file fix (2026-10-17)"): opencode 1.18.34's
// built-in read returns up to 50 KB per call (tool/read.ts L13-17: MAX_BYTES =
// 50 * 1024, DEFAULT_READ_LIMIT = 2000 lines, MAX_LINE_LENGTH = 2000). Task
// kane-08 asked qwen3.6 (65,536-token window, compaction at 57,344) to work in
// two files of 131 KB and 185 KB; every cycle it read both whole plus one
// continuation each (~240k chars, ~88k tokens), the window overflowed,
// opencode compacted, and the same four reads came back 17 to 19 times per run
// until the 45-minute timeout: 3 runs of 3, 0 edits.
//
// What it does:
//   1. caps every read at a share of the session's model window:
//      min(51200, floor(contextTokens * 0.08 * 3.3)) chars, about 17,300 at 64k
//      and no clamp at all for a 200k hosted model. It does that by lowering
//      the call's own `limit`, so read's footer ("Showing lines A-B of T. Use
//      offset=N to continue.") stays true;
//   2. appends one line to a clamped result saying why and what to do (grep,
//      then read just those lines);
//   3. gives each file a budget per compaction, floor(contextTokens * 0.25 *
//      3.3) chars served: once it is spent, further reads of that file get a
//      100-line window (SWE-agent's best window, Table 3 of
//      https://arxiv.org/html/2405.15793v3). A read is never refused;
//   4. resets those counters when the session compacts.
// HOMELAB_READ_MAX_CHARS=<n> replaces the computed cap; =off switches the whole
// plugin off (no clamp, no hint). HOMELAB_READ_BUDGET_LOG=<file> appends one
// JSON line per clamp (the harness sets it per run and counts them).
//
// Hooks, read at opencode v1.18.34 (re-checked at v1.19.5 (2026-10-31): those files unchanged;
// aec0b9a6d8898f68f923aaf08b7306d931fd9d76,
// packages/opencode/src):
//   - session/tools.ts L106-110 triggers tool.execute.before with
//     `{ args }` as the output, and L111 calls item.execute(args, ctx) with that
//     same object: a mutation of output.args.limit is what read runs with.
//     L121-125 triggers tool.execute.after with the result object, which L129
//     returns to the model: appending to output.output reaches it.
//   - tool/read.ts L233-237 resolves a relative filePath against
//     instance.directory; L331 reads `params.limit ?? 2000` from
//     `params.offset || 1`; L339 prints each line as `${n}: ${line}` joined
//     with "\n"; L162 cuts a line at 2000 chars and appends the suffix.
//   - session/llm/request.ts L69-73 (experimental.chat.system.transform, input
//     { sessionID?, model }) and L114-124 (chat.params, input { sessionID,
//     agent, model, ... }) both hand over the model; chat.params is the one
//     used (not experimental), the system transform only fills a gap.
//     model.limit.context is the window (plugin/src/index.ts L247-248, L291-292).
//   - session/compaction.ts L373-377 triggers experimental.session.compacting
//     on the path every compaction takes, an overflow-triggered one included
//     (the `input.overflow` branch at L340 is above it, in the same function).
// Pinned to what 1.18.34 does; tests/test-read-budget.ps1 checks the behaviour
// (the live part runs the real opencode), and any opencode upgrade must re-run it.

import { isAbsolute, resolve } from "node:path"
import {
  DEFAULT_CONTEXT_TOKENS, FRAME_CHARS, LOADED_KEY, MAX_CAP_CHARS, WINDOW_LINES,
  budgetHint, capChars, capHint, fileBudgetChars, fileLogger, fitLines, isOff, keyOf, naturalLines, scanFile,
} from "./read-budget/core.js"

// The helpers live in ./read-budget/core.js, shared with the 2.x plugin
// (./read-budget/index.js); re-exported so the 1.x tests see one module.
export * from "./read-budget/core.js"

// The plugin, with its state and logger injectable for tests. `directory` is
// the project directory read resolves a relative path against (PluginInput.directory).
export function createHooks(
  state = { contexts: new Map(), used: new Map(), pending: new Map(), clamps: 0 },
  log = () => {},
  directory = process.cwd(),
) {
  if (!state.contexts) state.contexts = new Map()
  if (!state.used) state.used = new Map()
  if (!state.pending) state.pending = new Map()
  const learn = (sessionID, model, onlyIfUnknown) => {
    const tokens = model && model.limit && Number(model.limit.context)
    if (!sessionID || !(tokens > 0)) return
    if (onlyIfUnknown && state.contexts.has(sessionID)) return
    state.contexts.set(sessionID, tokens)
  }
  const contextOf = (sessionID) => state.contexts.get(sessionID) ?? DEFAULT_CONTEXT_TOKENS
  const usedOf = (sessionID) => {
    if (!state.used.has(sessionID)) state.used.set(sessionID, new Map())
    return state.used.get(sessionID)
  }
  return {
    state,
    // The title and summary calls run a small model in the same session.
    "chat.params": async (input) => {
      if (!input || input.agent === "title" || input.agent === "summary") return
      learn(input.sessionID, input.model, false)
    },
    "experimental.chat.system.transform": async (input) => {
      learn(input && input.sessionID, input && input.model, true)
    },
    "tool.execute.before": async (input, output) => {
      if (isOff() || !input || input.tool !== "read" || !output || !output.args) return
      const args = output.args
      if (typeof args.filePath !== "string" || args.filePath === "") return
      const offset = args.offset === undefined || args.offset === null ? 1 : Number(args.offset) || 1
      const asked = args.limit === undefined || args.limit === null ? undefined : Number(args.limit)
      if (!Number.isFinite(offset) || offset < 1 || (asked !== undefined && !(asked >= 1))) return
      const path = isAbsolute(args.filePath) ? args.filePath : resolve(directory, args.filePath)
      const scan = scanFile(path)
      if (!scan || scan.lines.length < offset) return
      const tokens = contextOf(input.sessionID)
      const cap = capChars(tokens)
      const key = keyOf(path)
      const spent = (usedOf(input.sessionID).get(key) || 0) >= fileBudgetChars(tokens)
      const natural = naturalLines(scan.lines, offset, asked)
      // At read's own 50 KB there is nothing to add: its byte cut already applies.
      let target = Math.min(
        asked ?? Infinity,
        cap >= MAX_CAP_CHARS ? Infinity : fitLines(scan.lines, offset, Math.max(1, cap - path.length - FRAME_CHARS)),
      )
      if (spent) target = Math.min(target, WINDOW_LINES)
      if (target >= natural) return
      args.limit = target
      const reason = spent ? "budget" : "cap"
      state.pending.set(input.callID, {
        sessionID: input.sessionID, path: args.filePath, key, offset, asked: asked ?? null, set: target, reason,
        hint: spent ? budgetHint(args.filePath, usedOf(input.sessionID).get(key) || 0) : capHint(args.filePath, scan),
      })
    },
    "tool.execute.after": async (input, output) => {
      if (!input || input.tool !== "read" || !output || typeof output.output !== "string") return
      const served = output.output.length
      if (input.sessionID) {
        const used = usedOf(input.sessionID)
        const key = keyOf(
          isAbsolute((input.args && input.args.filePath) || "") ? input.args.filePath : resolve(directory, (input.args && input.args.filePath) || ""),
        )
        if (input.args && typeof input.args.filePath === "string") used.set(key, (used.get(key) || 0) + served)
      }
      const p = state.pending.get(input.callID)
      if (!p) return
      state.pending.delete(input.callID)
      output.output += "\n" + p.hint
      state.clamps = (state.clamps || 0) + 1
      log("clamp", {
        sessionID: p.sessionID, path: p.path, offset: p.offset, asked: p.asked, set: p.set, reason: p.reason, chars: served,
      })
    },
    // The budget is per compaction: the compacted context no longer holds what
    // was read (compaction.ts L373-377, every compaction).
    "experimental.session.compacting": async (input) => {
      if (input && input.sessionID) state.used.delete(input.sessionID)
    },
  }
}

// opencode's v1 plugin module (plugin/shared.ts readV1Plugin, 1.18.34): a
// default export with an `id` and server(); see compaction-continue.js. One copy
// per project directory (core.js LOADED_KEY).
export default {
  id: "homelab-read-budget",
  server: async (input) => {
    const log = fileLogger(process.env.HOMELAB_READ_BUDGET_LOG)
    const loaded = (globalThis[LOADED_KEY] ??= new Set())
    const dir = (input && input.directory) || ""
    if (loaded.has(dir)) {
      log("duplicate copy skipped", { directory: dir })
      return {}
    }
    loaded.add(dir)
    const { state, ...hooks } = createHooks(undefined, log, dir || process.cwd())
    log("loaded", { off: isOff(), capOverride: process.env.HOMELAB_READ_MAX_CHARS || null })
    return hooks
  },
}
