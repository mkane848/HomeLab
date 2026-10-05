// compaction-continue.js - an opencode plugin: keep working after a compaction.
//
// Why (docs/roadmap.md -> "Context overflow"): after an automatic compaction
// opencode 1.18.34 adds a synthetic user message, "Continue if you have next
// steps, or stop and ask for clarification if you are unsure how to proceed."
// Local seats often take the second half: a few steps of re-reading, then a
// recap, then a stop. The owner chats in one window and never wants to nudge
// machinery; a fixed "carry on" after such a stall resumed 4 of 4 stalls in the
// 2026-10-04/05 diagnostic (tests/results/compaction-nudge/).
//
// What it does, all inside the session (it never sends a message itself):
//   1. remembers each session's first real user message (the original request);
//   2. on every model call, rewrites opencode's continue message into
//      CONTINUE_TEXT plus that original request, verbatim - the stored message
//      is untouched, only what the model is sent changes;
//   3. asks the compaction summary to carry the original request verbatim.
// It keeps the owner's approvals: the model is told to stop and ask for the
// owner's decisions (2026-10-04: while tuning is early, more approvals rather
// than fewer).
//
// Hooks used are EXPERIMENTAL in opencode (experimental.chat.messages.transform,
// experimental.session.compacting) and the continue message's marker is "not a
// stable plugin contract" (session/compaction.ts). Pinned to what 1.18.34 does;
// tests/test-compaction-plugin.ps1 checks the behaviour, and any opencode
// upgrade must re-run it.

import { appendFileSync } from "node:fs"

export const CONTINUE_MARKER ="Continue if you have next steps, or stop and ask for clarification"

export const CONTINUE_TEXT =
  "Your context was just compacted; the summary above is what you have. Carry on with the original task now: " +
  "use your tools to make the change and check it, instead of describing next steps. Stop and ask only for a " +
  "decision that is mine to make: approving a plan, a requirement that is unclear, or anything destructive or " +
  "hard to undo (deleting files, force-pushing, secrets, dependencies, CI)."

export const MAX_ORIGINAL_CHARS = 6000

function clip(text) {
  return text.length <= MAX_ORIGINAL_CHARS ? text : text.slice(0, MAX_ORIGINAL_CHARS) + "\n[... cut]"
}

function textOf(parts) {
  return (parts || [])
    .filter((p) => p && p.type === "text" && !p.synthetic && !p.ignored && typeof p.text === "string")
    .map((p) => p.text)
    .join("\n")
    .trim()
}

// opencode's own continue message: marked in metadata (1.18.34), or recognised
// by its text if the marker ever disappears.
export function isContinuePart(part) {
  if (!part || part.type !== "text" || typeof part.text !== "string") return false
  if (part.metadata && part.metadata.compaction_continue === true) return true
  return part.synthetic === true && part.text.includes(CONTINUE_MARKER)
}

export function continueText(original) {
  if (!original) return CONTINUE_TEXT
  return CONTINUE_TEXT + "\n\nThe original request, verbatim:\n<original-request>\n" + clip(original) + "\n</original-request>"
}

// The plugin, with its state and logger injectable for tests. `log(message,
// extra)` records each rewrite: the run's transcript shows the STORED continue
// message, so the log is the only evidence of what the model was sent.
export function createHooks(state = { originals: new Map(), rewrites: 0 }, log = () => {}) {
  const remember = (sessionID, text) => {
    if (sessionID && text && !state.originals.has(sessionID)) state.originals.set(sessionID, text)
  }
  return {
    state,
    // A new user message: the first real one is the original request.
    "chat.message": async (input, output) => {
      remember(input && input.sessionID, textOf(output && output.parts))
    },
    "experimental.chat.messages.transform": async (_input, output) => {
      const messages = (output && output.messages) || []
      for (const m of messages) {
        if (!m || !m.info || m.info.role !== "user") continue
        // A request seen before this plugin loaded (a resumed session).
        const text = textOf(m.parts)
        if (text && !(m.parts || []).some(isContinuePart)) remember(m.info.sessionID, text)
      }
      for (const m of messages) {
        if (!m || !m.info || m.info.role !== "user") continue
        for (const part of m.parts || []) {
          if (!isContinuePart(part)) continue
          const original = state.originals.get(m.info.sessionID)
          part.text = continueText(original)
          state.rewrites = (state.rewrites || 0) + 1
          log("rewrote the post-compaction continue message", { sessionID: m.info.sessionID, withOriginal: !!original })
        }
      }
    },
    "experimental.session.compacting": async (input, output) => {
      const original = state.originals.get(input && input.sessionID)
      if (original && output && Array.isArray(output.context)) {
        output.context.push(
          "Carry the user's original request into the summary verbatim, under its own heading, so the work can " +
            "resume from it:\n<original-request>\n" + clip(original) + "\n</original-request>",
        )
      }
    },
  }
}

// opencode's v1 plugin module (plugin/shared.ts readV1Plugin, 1.18.34): a
// default export with an `id` (required for a plugin loaded by path) and
// server(). With it, opencode does not treat the named exports above as
// plugins - its legacy loader calls every export and rejects non-functions.
// Evidence log: when HOMELAB_COMPACTION_PLUGIN_LOG names a file, each event is
// appended to it as a JSON line (the harness sets it per run and counts the
// rewrites). opencode's client.app.log did not reach any log readable here
// (1.18.34, 2026-10-05), so a file it is. Unset: no logging at all.
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

export default {
  id: "homelab-compaction-continue",
  server: async () => {
    const log = fileLogger(process.env.HOMELAB_COMPACTION_PLUGIN_LOG)
    const { state, ...hooks } = createHooks(undefined, log)
    log("loaded", {})
    return hooks
  },
}
