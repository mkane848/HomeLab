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
// What it does:
//   1. remembers each session's first real user message (the original request);
//   2. on every model call, rewrites opencode's continue message into
//      CONTINUE_TEXT plus that original request, verbatim - the stored message
//      is untouched, only what the model is sent changes;
//   3. asks the compaction summary to carry the original request verbatim;
//   4. when a session goes idle after an auto-continued compaction and the
//      model's last step ended without a tool call, an error or a question,
//      sends CONTINUE_TEXT as a new user message: once per compaction, at most
//      IDLE_CONTINUE_MAX per session, never after the owner has written since
//      the compaction. 1-3 alone left 2 of 3 kane-07 x qwen3.6 runs stalled
//      (2026-10-05 trial); the same message sent as a fresh turn is the
//      diagnostic's 2 of 3 passes. HOMELAB_COMPACTION_IDLE_CONTINUE=off turns
//      4 off (the harness does: `opencode run` exits at idle, so a message sent
//      then would land in a session nobody answers).
// It keeps the owner's approvals: the model is told to stop and ask for the
// owner's decisions (2026-10-04: while tuning is early, more approvals rather
// than fewer), and a reply that ends in a question is never continued.
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

export const IDLE_CONTINUE_MAX = 3

// The plugin's own idle continue: marked in metadata, or recognised by its text.
export function isIdleContinueMessage(message) {
  if (!message || !message.info || message.info.role !== "user") return false
  return (message.parts || []).some(
    (p) =>
      p && p.type === "text" && typeof p.text === "string" &&
      ((p.metadata && p.metadata.homelab_idle_continue === true) || p.text.trim() === CONTINUE_TEXT),
  )
}

// The last paragraph of a reply asks the owner something: leave it to them.
export function asksOwner(text) {
  const paragraphs = (text || "").trim().split(/\n\s*\n/)
  return paragraphs[paragraphs.length - 1].includes("?")
}

// Should a session that just went idle get the continue message? `messages` is
// opencode's history, oldest first ({ info, parts }). Returns { send, reason }
// and, to send, the agent and model of opencode's continue message, so the turn
// runs where the compacted one did.
export function idleDecision(messages) {
  const list = messages || []
  let anchor = -1
  for (let i = list.length - 1; i >= 0; i--) {
    const m = list[i]
    if (m && m.info && m.info.role === "user" && (m.parts || []).some(isContinuePart)) {
      anchor = i
      break
    }
  }
  if (anchor < 0) return { send: false, reason: "no auto-continued compaction" }
  if (list.filter(isIdleContinueMessage).length >= IDLE_CONTINUE_MAX)
    return { send: false, reason: `session already continued ${IDLE_CONTINUE_MAX} times` }
  for (const m of list.slice(anchor + 1)) {
    if (!m || !m.info || m.info.role !== "user") continue
    if (isIdleContinueMessage(m)) return { send: false, reason: "already continued after this compaction" }
    if (textOf(m.parts)) return { send: false, reason: "the owner has written since the compaction" }
  }
  const last = list[list.length - 1]
  if (anchor === list.length - 1 || !last.info || last.info.role !== "assistant")
    return { send: false, reason: "the model has not answered the continue message" }
  if (last.info.summary) return { send: false, reason: "the last message is a compaction summary" }
  if (last.info.error) return { send: false, reason: "the last step ended in an error or was stopped" }
  if ((last.parts || []).some((p) => p && p.type === "tool")) return { send: false, reason: "the last step called a tool" }
  if (asksOwner(textOf(last.parts))) return { send: false, reason: "the model asked a question" }
  const info = list[anchor].info
  return { send: true, reason: "stopped without a tool call after a compaction", agent: info.agent, model: info.model }
}

// The plugin, with its state and logger injectable for tests. `log(message,
// extra)` records each rewrite: the run's transcript shows the STORED continue
// message, so the log is the only evidence of what the model was sent.
// `client` is opencode's SDK client (PluginInput.client); without one, or with
// HOMELAB_COMPACTION_IDLE_CONTINUE=off, there is no idle continue.
export function createHooks(
  state = { originals: new Map(), rewrites: 0, idleBusy: new Set(), idleSent: 0 },
  log = () => {},
  client = undefined,
) {
  const remember = (sessionID, text) => {
    if (sessionID && text && !state.originals.has(sessionID)) state.originals.set(sessionID, text)
  }
  if (!state.idleBusy) state.idleBusy = new Set()
  const idleOn = () => !!client && `${process.env.HOMELAB_COMPACTION_IDLE_CONTINUE || ""}`.toLowerCase() !== "off"
  const onIdle = async (sessionID) => {
    if (!sessionID || !idleOn() || state.idleBusy.has(sessionID)) return
    state.idleBusy.add(sessionID)
    try {
      const session = await client.session.get({ path: { id: sessionID } })
      // A subagent's session reports back to its parent; continuing it is the parent's call.
      if (session && session.data && session.data.parentID) return
      const res = await client.session.messages({ path: { id: sessionID } })
      if (!res || !Array.isArray(res.data)) {
        log("idle continue: could not read the session", { sessionID })
        return
      }
      const decision = idleDecision(res.data)
      if (!decision.send) {
        if (decision.reason !== "no auto-continued compaction") log("idle continue skipped", { sessionID, reason: decision.reason })
        return
      }
      const body = { parts: [{ type: "text", text: CONTINUE_TEXT, metadata: { homelab_idle_continue: true } }] }
      if (decision.agent) body.agent = decision.agent
      if (decision.model && decision.model.providerID && decision.model.modelID)
        body.model = { providerID: decision.model.providerID, modelID: decision.model.modelID }
      const sent = await client.session.promptAsync({ path: { id: sessionID }, body })
      if (sent && sent.error) {
        log("idle continue: send failed", { sessionID, error: String(sent.error.name || sent.error) })
        return
      }
      state.idleSent = (state.idleSent || 0) + 1
      log("sent the idle continue message", { sessionID })
    } catch (e) {
      log("idle continue: error", { sessionID, error: String((e && e.message) || e) })
    } finally {
      state.idleBusy.delete(sessionID)
    }
  }
  return {
    state,
    // opencode 1.18.34 publishes session.status {type: "idle"} and the
    // deprecated session.idle for the same moment; idleBusy and the history
    // check (one continue per compaction) keep that to one message.
    event: async ({ event } = {}) => {
      if (!event) return
      const p = event.properties || {}
      if (event.type === "session.idle" || (event.type === "session.status" && p.status && p.status.type === "idle"))
        await onIdle(p.sessionID)
    },
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

// One copy per project directory. Listed twice (the global config plus a
// project or OPENCODE_CONFIG overlay, even from two checkouts), two copies
// would each send an idle continue, and the session would get it twice
// (2026-10-06: the live check against an installed plugin). opencode loads
// plugins per directory instance, so the guard keys on the directory, not the
// process.
const LOADED_KEY = Symbol.for("homelab-compaction-continue.loaded")

export default {
  id: "homelab-compaction-continue",
  server: async (input) => {
    const log = fileLogger(process.env.HOMELAB_COMPACTION_PLUGIN_LOG)
    const loaded = (globalThis[LOADED_KEY] ??= new Set())
    const dir = (input && input.directory) || ""
    if (loaded.has(dir)) {
      log("duplicate copy skipped", { directory: dir })
      return {}
    }
    loaded.add(dir)
    const client = input && input.client
    const { state, ...hooks } = createHooks(undefined, log, client)
    log("loaded", { idleContinue: !!client && `${process.env.HOMELAB_COMPACTION_IDLE_CONTINUE || ""}`.toLowerCase() !== "off" })
    return hooks
  },
}
