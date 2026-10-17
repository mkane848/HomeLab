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
// Hooks, read at opencode v1.18.34 (aec0b9a6d8898f68f923aaf08b7306d931fd9d76,
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

import { appendFileSync, closeSync, openSync, readSync, statSync } from "node:fs"
import { extname, isAbsolute, resolve } from "node:path"

export const CHARS_PER_TOKEN = 3.3
export const CAP_FRACTION = 0.08
export const BUDGET_FRACTION = 0.25
export const MAX_CAP_CHARS = 51200
export const DEFAULT_CONTEXT_TOKENS = 65536
export const WINDOW_LINES = 100
// read.ts L13-17.
export const READ_DEFAULT_LIMIT = 2000
export const READ_MAX_LINE = 2000
export const READ_LINE_SUFFIX = `... (line truncated to ${READ_MAX_LINE} chars)`
export const READ_MAX_BYTES = 50 * 1024
// What read prints around the lines (<path>, <type>, <content>, the footer,
// </content>), kept out of the line budget so a whole result stays under the cap.
export const FRAME_CHARS = 160
// Files past this are scanned only for their first MAX_SCAN_BYTES.
export const MAX_SCAN_BYTES = 16 * 1024 * 1024

export function capChars(contextTokens, env = process.env) {
  const raw = `${env.HOMELAB_READ_MAX_CHARS ?? ""}`.trim()
  const override = Number(raw)
  if (raw !== "" && raw.toLowerCase() !== "off" && Number.isFinite(override) && override > 0) return Math.floor(override)
  const tokens = Number.isFinite(contextTokens) && contextTokens > 0 ? contextTokens : DEFAULT_CONTEXT_TOKENS
  return Math.min(MAX_CAP_CHARS, Math.floor(tokens * CAP_FRACTION * CHARS_PER_TOKEN))
}

export function fileBudgetChars(contextTokens) {
  const tokens = Number.isFinite(contextTokens) && contextTokens > 0 ? contextTokens : DEFAULT_CONTEXT_TOKENS
  return Math.floor(tokens * BUDGET_FRACTION * CHARS_PER_TOKEN)
}

export function isOff(env = process.env) {
  return `${env.HOMELAB_READ_MAX_CHARS ?? ""}`.trim().toLowerCase() === "off"
}

// One printed line of read's output, in chars: "<n>: " + the (cut) line + the
// newline that joins it to the next.
export function printedLength(lineNumber, line) {
  const body = line.length > READ_MAX_LINE ? READ_MAX_LINE + READ_LINE_SUFFIX.length : line.length
  return String(lineNumber).length + 2 + body + 1
}

// How many lines from `offset` (1-based) fit in `budget` printed chars: at least
// one (a single long line is read's own 2000-char cut), at most `max`.
export function fitLines(lines, offset, budget, max = Infinity) {
  let used = 0
  let n = 0
  for (let i = offset - 1; i < lines.length && n < max; i++) {
    const len = printedLength(i + 1, lines[i])
    if (n > 0 && used + len > budget) break
    used += len
    n++
  }
  return Math.max(n, 1)
}

// What read would return on its own: its 2000-line default, the caller's limit
// and its 50 KB byte cap (L157-176, which counts a line's bytes plus a newline).
export function naturalLines(lines, offset, asked) {
  const max = Math.min(asked ?? READ_DEFAULT_LIMIT, lines.length - offset + 1)
  let bytes = 0
  let n = 0
  for (let i = offset - 1; i < lines.length && n < max; i++) {
    const l = lines[i]
    const cut = l.length > READ_MAX_LINE ? l.substring(0, READ_MAX_LINE) + READ_LINE_SUFFIX : l
    const size = Buffer.byteLength(cut, "utf-8") + (n > 0 ? 1 : 0)
    if (bytes + size > READ_MAX_BYTES) break
    bytes += size
    n++
  }
  return n
}

const NON_TEXT_EXT = new Set([
  ".zip", ".tar", ".gz", ".exe", ".dll", ".so", ".class", ".jar", ".war", ".7z", ".doc", ".docx", ".xls", ".xlsx",
  ".ppt", ".pptx", ".odt", ".ods", ".odp", ".bin", ".dat", ".obj", ".o", ".a", ".lib", ".wasm", ".pyc", ".pyo",
  ".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf",
])

// read.ts L182-227 (isBinaryFile) plus the image and PDF types it returns as
// attachments, from the extension and the first 4096 bytes.
export function looksNonText(path, sample) {
  if (NON_TEXT_EXT.has(extname(path).toLowerCase())) return true
  if (sample.length === 0) return false
  let odd = 0
  for (let i = 0; i < sample.length; i++) {
    if (sample[i] === 0) return true
    if (sample[i] < 9 || (sample[i] > 13 && sample[i] < 32)) odd++
  }
  return odd / sample.length > 0.3
}

// The file as read splits it (Stream.splitLines: \n, \r\n or \r, no empty last
// line after a final newline). null when the call is not ours to touch: missing,
// a directory, binary, an image or unreadable.
export function scanFile(path) {
  try {
    const st = statSync(path)
    if (!st.isFile()) return null
    const want = Math.min(st.size, MAX_SCAN_BYTES)
    const buf = Buffer.alloc(want)
    const fd = openSync(path, "r")
    try {
      let got = 0
      while (got < want) {
        const r = readSync(fd, buf, got, want - got, got)
        if (r <= 0) break
        got += r
      }
    } finally {
      closeSync(fd)
    }
    if (looksNonText(path, buf.subarray(0, Math.min(4096, buf.length)))) return null
    let text = buf.toString("utf-8")
    const complete = st.size <= MAX_SCAN_BYTES
    const lines = text.split(/\r\n|\r|\n/)
    // A final newline leaves an empty last element; a cut file leaves a partial one.
    if (lines.length > 0 && (lines[lines.length - 1] === "" || !complete)) lines.pop()
    return { size: st.size, lines, complete }
  } catch {
    return null
  }
}

function keyOf(path) {
  return process.platform === "win32" ? path.replace(/\\/g, "/").toLowerCase() : path
}

function kb(bytes) {
  return `${Math.max(1, Math.round(bytes / 1024))} KB`
}

export function capHint(path, scan) {
  const count = scan.lines.length.toLocaleString("en-US")
  return (
    `(read-budget: ${path} is ${kb(scan.size)}, ${scan.complete ? "" : "more than "}${count} lines, more than fits in your ` +
    `context beside the rest of the work. Use grep to find what you need, then read just those lines with offset and limit.)`
  )
}

export function budgetHint(path, spent) {
  return (
    `(read-budget: ${path} has already used its read budget (${kb(spent)} served) since the last compaction, so this read is ` +
    `limited to ${WINDOW_LINES} lines. Use grep to find what you need, then read only those lines with offset and limit.)`
  )
}

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
// default export with an `id` and server(); see compaction-continue.js.
// Evidence log: when HOMELAB_READ_BUDGET_LOG names a file, each clamp is
// appended to it as a JSON line. Unset: no logging at all.
export function fileLogger(path) {
  return (message, extra) => {
    if (!path) return
    try {
      appendFileSync(path, JSON.stringify({ time: new Date().toISOString(), message, ...extra }) + "\n")
    } catch {
      // logging must never break a session
    }
  }
}

// One copy per project directory, as compaction-continue.js: listed twice
// (global config plus an overlay) it would clamp, and hint, twice.
const LOADED_KEY = Symbol.for("homelab-read-budget.loaded")

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
