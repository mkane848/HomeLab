// Unit checks for opencode/plugins/compaction-continue.js, run by
// tests/test-compaction-plugin.ps1 (node, no dependencies). Prints one
// "PASS name" / "FAIL name" line per check and "CONTINUE_TEXT=<json>" for the
// runner's cross-check against test-tasks.ps1's nudge text. Exit 1 on a failure.
import { pathToFileURL } from "node:url"
import { mkdtempSync, readFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const pluginPath = process.argv[2]
const mod = await import(pathToFileURL(pluginPath).href)
const { createHooks, continueText, isContinuePart, fileLogger, CONTINUE_TEXT, CONTINUE_MARKER, MAX_ORIGINAL_CHARS } = mod

let failed = 0
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  console.log(`${ok ? "PASS" : "FAIL"} ${name}`)
  if (!ok) {
    console.log(`     expected: ${JSON.stringify(expected)}`)
    console.log(`     got:      ${JSON.stringify(actual)}`)
    failed++
  }
}

const opencodeContinue = (sessionID, extra = {}) => ({
  info: { role: "user", sessionID },
  parts: [{ type: "text", synthetic: true, metadata: { compaction_continue: true },
    text: "Continue if you have next steps, or stop and ask for clarification if you are unsure how to proceed.", ...extra }],
})
const userMsg = (sessionID, text) => ({ info: { role: "user", sessionID }, parts: [{ type: "text", text }] })
const assistantMsg = (sessionID, text) => ({ info: { role: "assistant", sessionID }, parts: [{ type: "text", text }] })

// --- module shape: what opencode 1.18.34's loader needs (plugin/shared.ts) ---
check("default export has a string id", typeof mod.default.id, "string")
check("default export has server()", typeof mod.default.server, "function")
const logFile = join(mkdtempSync(join(tmpdir(), "ccplugin-")), "log.jsonl")
process.env.HOMELAB_COMPACTION_PLUGIN_LOG = logFile
const hooksFromServer = await mod.default.server({})
check("server() returns the three hooks", Object.keys(hooksFromServer).sort(),
  ["chat.message", "experimental.chat.messages.transform", "experimental.session.compacting"])
check("server() logs 'loaded' to HOMELAB_COMPACTION_PLUGIN_LOG", readFileSync(logFile, "utf8").includes('"message":"loaded"'), true)
await hooksFromServer["experimental.chat.messages.transform"]({}, { messages: [opencodeContinue("sL")] })
check("a rewrite is logged with its session", readFileSync(logFile, "utf8").includes('"sessionID":"sL"'), true)
delete process.env.HOMELAB_COMPACTION_PLUGIN_LOG
check("no log variable: no logging, no throw", typeof (await mod.default.server({})), "object")
check("a log path that cannot be written does not throw", (fileLogger(join(logFile, "no", "such", "dir.jsonl"))("x", {}), true), true)

// --- recognising opencode's continue message ---
check("marked continue part", isContinuePart(opencodeContinue("s").parts[0]), true)
check("unmarked but synthetic with the marker text (marker removed upstream)",
  isContinuePart({ type: "text", synthetic: true, text: CONTINUE_MARKER + " if you are unsure." }), true)
check("a user typing the same words is not it", isContinuePart({ type: "text", text: CONTINUE_MARKER }), false)
check("a tool part is not it", isContinuePart({ type: "tool", tool: "read" }), false)

// --- the original request ---
{
  const h = createHooks()
  await h["chat.message"]({ sessionID: "s1" }, { parts: [{ type: "text", text: "fix the digest split" }] })
  await h["chat.message"]({ sessionID: "s1" }, { parts: [{ type: "text", text: "a later message" }] })
  await h["chat.message"]({ sessionID: "s2" }, { parts: [{ type: "text", synthetic: true, text: "synthetic" }, { type: "text", text: "second session" }] })
  check("first real user message is the original", h.state.originals.get("s1"), "fix the digest split")
  check("synthetic parts are not part of it", h.state.originals.get("s2"), "second session")
}

// --- the rewrite (what the model is sent) ---
{
  const h = createHooks()
  await h["chat.message"]({ sessionID: "s1" }, { parts: [{ type: "text", text: "fix the digest split" }] })
  const output = { messages: [userMsg("s1", "fix the digest split"), assistantMsg("s1", "## Objective ..."), opencodeContinue("s1")] }
  await h["experimental.chat.messages.transform"]({}, output)
  const text = output.messages[2].parts[0].text
  check("continue message rewritten to CONTINUE_TEXT + original", text, continueText("fix the digest split"))
  check("...it starts with CONTINUE_TEXT", text.startsWith(CONTINUE_TEXT), true)
  check("...and carries the original verbatim", text.includes("<original-request>\nfix the digest split\n</original-request>"), true)
  check("...the invitation to stop is gone", text.includes("stop and ask for clarification if you are unsure"), false)
  check("...the owner's approvals are kept", text.includes("Stop and ask only for a decision that is mine to make"), true)
  check("the user's own message is untouched", output.messages[0].parts[0].text, "fix the digest split")
  check("the assistant's message is untouched", output.messages[1].parts[0].text, "## Objective ...")
  check("rewrites counted", h.state.rewrites, 1)
}
{
  // A session the plugin first sees after compaction: no original known.
  const h = createHooks()
  const output = { messages: [assistantMsg("s9", "## Objective ..."), opencodeContinue("s9")] }
  await h["experimental.chat.messages.transform"]({}, output)
  check("no original known: CONTINUE_TEXT alone", output.messages[1].parts[0].text, CONTINUE_TEXT)
  check("...and the continue message is not taken for the original", h.state.originals.has("s9"), false)
}
{
  // Resumed session: the original is in the history the transform sees.
  const h = createHooks()
  const output = { messages: [userMsg("s3", "add a status guard"), opencodeContinue("s3")] }
  await h["experimental.chat.messages.transform"]({}, output)
  check("original learned from history when chat.message never fired", h.state.originals.get("s3"), "add a status guard")
  check("...and used in the rewrite", output.messages[1].parts[0].text, continueText("add a status guard"))
}
{
  const h = createHooks()
  const long = "x".repeat(MAX_ORIGINAL_CHARS + 50)
  await h["chat.message"]({ sessionID: "s4" }, { parts: [{ type: "text", text: long }] })
  const out = { messages: [opencodeContinue("s4")] }
  await h["experimental.chat.messages.transform"]({}, out)
  check("a very long original is clipped", out.messages[0].parts[0].text.includes("[... cut]"), true)
}

// --- the compaction prompt ---
{
  const h = createHooks()
  await h["chat.message"]({ sessionID: "s5" }, { parts: [{ type: "text", text: "split long digests" }] })
  const out = { context: [], prompt: undefined }
  await h["experimental.session.compacting"]({ sessionID: "s5" }, out)
  check("compaction context asks to keep the original verbatim", out.context.length === 1 && out.context[0].includes("<original-request>\nsplit long digests\n</original-request>"), true)
  check("...without replacing opencode's prompt", out.prompt, undefined)
  const none = { context: [] }
  await h["experimental.session.compacting"]({ sessionID: "unknown" }, none)
  check("unknown session: nothing added", none.context.length, 0)
}

console.log("CONTINUE_TEXT=" + JSON.stringify(CONTINUE_TEXT))
process.exit(failed ? 1 : 0)
