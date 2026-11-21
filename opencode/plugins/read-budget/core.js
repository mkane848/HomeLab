// read-budget/core.js - what both read-budget entrypoints share: the cap
// arithmetic, how read splits and prints a file, the hints and the evidence log.
// No opencode API here. Imported by:
//   - ../read-budget.js       the opencode 1.x plugin ({id, server()}, 1.19.5)
//   - ./index.js              the opencode 2.x plugin ({id, setup(ctx)}, 2.3.2)
// Why the plugin exists and what it does: the header of ./index.js.
//
// The two reads differ in only a few ways that matter here; `dialect` ("v1" or
// "v2") picks them:
//   - v1 (1.18.34-1.19.5, tool/read.ts) splits a file on \n, \r\n or \r and calls
//     a file binary from its extension list plus the first 4096 bytes;
//   - v2 (2.3.2, the bundled ReadTool.read) splits on \n only, drops one trailing
//     \r per line and a leading BOM, refuses a file with a NUL byte and returns
//     images and PDFs (sniffed from their magic bytes) as attachments.
// Both cut a line at 2000 chars with the same suffix, stop at 2000 lines and at
// 50 KiB counted as each cut line's UTF-8 bytes plus a newline (v2's constants:
// Jt=2000, $t=51200, Wf=2000, Ns, read from the 2.3.2 binary on 2026-11-21).

import { appendFileSync, closeSync, openSync, readSync, statSync } from "node:fs"
import { extname } from "node:path"

export const CHARS_PER_TOKEN = 3.3
export const CAP_FRACTION = 0.08
export const BUDGET_FRACTION = 0.25
export const MAX_CAP_CHARS = 51200
export const DEFAULT_CONTEXT_TOKENS = 65536
export const WINDOW_LINES = 100
// read.ts L13-17 (1.x); the same values in 2.x.
export const READ_DEFAULT_LIMIT = 2000
export const READ_MAX_LINE = 2000
export const READ_LINE_SUFFIX = `... (line truncated to ${READ_MAX_LINE} chars)`
export const READ_MAX_BYTES = 50 * 1024
// What read prints around the lines (1.x: <path>, <type>, <content>, the footer,
// </content>; 2.x: "Read file <path>, lines A-B" and "[Output truncated. Continue
// reading with offset: N]"), kept out of the line budget so a whole result stays
// under the cap. The path itself is counted separately.
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
// and its 50 KB byte cap (1.x read.ts L157-176, 2.x Rs; both count a line's
// bytes plus a newline).
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

// 1.x read.ts L182-227 (isBinaryFile) plus the image and PDF types it returns as
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

const startsWith = (buf, bytes) => bytes.every((b, i) => buf[i] === b)

// 2.x: the media types read attaches (png, jpeg, gif, webp, pdf, sniffed from
// the bytes, not the name), and the NUL that makes it refuse a file as binary.
export function looksNonTextV2(buf) {
  if (startsWith(buf, [137, 80, 78, 71, 13, 10, 26, 10])) return true // png
  if (startsWith(buf, [255, 216, 255])) return true // jpeg
  const head = String.fromCharCode(...buf.subarray(0, 6))
  if (head === "GIF87a" || head === "GIF89a") return true
  if (startsWith(buf, [37, 80, 68, 70, 45])) return true // %PDF-
  if (startsWith(buf, [82, 73, 70, 70]) && startsWith(buf.subarray(8), [87, 69, 66, 80])) return true // RIFF....WEBP
  return buf.includes(0)
}

// The file as read splits it, with no empty last line after a final newline.
// null when the call is not ours to touch: missing, a directory, binary, an
// image or unreadable.
export function scanFile(path, dialect = "v1") {
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
    if (dialect === "v2" ? looksNonTextV2(buf) : looksNonText(path, buf.subarray(0, Math.min(4096, buf.length)))) return null
    let text = buf.toString("utf-8")
    const complete = st.size <= MAX_SCAN_BYTES
    let lines
    if (dialect === "v2") {
      if (text.startsWith("﻿")) text = text.slice(1)
      lines = text.split("\n").map((l) => (l.endsWith("\r") ? l.slice(0, -1) : l))
    } else {
      lines = text.split(/\r\n|\r|\n/)
    }
    // A final newline leaves an empty last element; a cut file leaves a partial one.
    if (lines.length > 0 && (lines[lines.length - 1] === "" || !complete)) lines.pop()
    return { size: st.size, lines, complete }
  } catch {
    return null
  }
}

// One key per file for the per-file budget (Windows paths are case-insensitive).
export function keyOf(path) {
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

// One copy per project directory: listed twice (global config plus an overlay)
// it would clamp, and hint, twice.
export const LOADED_KEY = Symbol.for("homelab-read-budget.loaded")
