// Live check of opencode/plugins/compaction-continue.js inside the REAL opencode
// (`opencode serve`), against a scripted stand-in model. Run by
// tests/test-compaction-plugin.ps1 (node, no dependencies). The stand-in speaks
// the OpenAI chat-completions stream and plays one stalled session:
//   1. the task: one tool call (read), reporting a prompt big enough that
//      opencode compacts before the next step;
//   2. opencode's compaction request: a summary;
//   3. the step after opencode's continue message: a recap and a stop, the
//      kane-07 x qwen3.6 shape (2026-10-05);
//   4. the plugin's idle continue: "FIXTURE-DONE".
// Checks: the plugin loaded in opencode; the compaction prompt carried the
// original request; the model saw the rewritten continue message; the session
// got exactly one idle continue, which the model was sent as is; nothing more
// after the model finished. Prints "PASS name" / "FAIL name" lines; "SKIP ..."
// and exit 0 when opencode cannot be started. Exit 1 on a failure.
//
// Usage: node test-compaction-plugin-live.mjs <plugin.js> [opencode command]
import { createServer } from "node:http"
import { spawn, execSync } from "node:child_process"
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

const pluginPath = process.argv[2]
const opencodeCmd = process.argv[3] || "opencode"
const { CONTINUE_TEXT } = await import(pathToFileURL(pluginPath).href)

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

// --- the stand-in model ---
const seen = { task: 0, compaction: 0, compactionHadOriginal: false, rewritten: 0, unrewritten: 0, idleContinue: 0, other: [] }
const textOf = (content) =>
  typeof content === "string" ? content : (content || []).map((p) => (p && typeof p.text === "string" ? p.text : "")).join("\n")
function reply(body) {
  const msgs = body.messages || []
  const lastUser = [...msgs].reverse().find((m) => m.role === "user")
  const last = textOf(lastUser && lastUser.content)
  const hasTools = Array.isArray(body.tools) && body.tools.length > 0
  if (!hasTools) {
    if (last.includes("<conversation>")) {
      seen.compaction++
      seen.compactionHadOriginal ||= last.includes("<original-request>") && last.includes("FIXTURE-TASK")
      return { text: "## Goal\nFIXTURE-TASK: fix notes.txt.\n\n## Progress\nRead notes.txt.", usage: 300 }
    }
    return { text: "Fixture session", usage: 50 } // title
  }
  if (last.includes(CONTINUE_TEXT) && last.includes("<original-request>")) {
    seen.rewritten++
    return { text: "Now I have the full picture. The bug is the second line of notes.txt.", usage: 600 }
  }
  if (last.trim() === CONTINUE_TEXT) {
    seen.idleContinue++
    return { text: "FIXTURE-DONE: fixed notes.txt.", usage: 700 }
  }
  if (last.includes("Continue if you have next steps")) {
    seen.unrewritten++
    return { text: "Recap without the rewrite.", usage: 600 }
  }
  if (last.includes("FIXTURE-TASK") && msgs[msgs.length - 1].role === "user") {
    seen.task++
    return { tool: { name: "read", args: { filePath: join(project, "notes.txt") } }, usage: 19500 }
  }
  seen.other.push(last.slice(0, 80))
  return { text: "unexpected request", usage: 600 }
}
function sse(res, r) {
  const base = { id: "chatcmpl-fx", object: "chat.completion.chunk", created: 0, model: "m" }
  const send = (o) => res.write(`data: ${JSON.stringify({ ...base, ...o })}\n\n`)
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" })
  if (r.tool) {
    send({ choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: "call_fx1", type: "function",
      function: { name: r.tool.name, arguments: JSON.stringify(r.tool.args) } }] }, finish_reason: null }] })
  } else {
    send({ choices: [{ index: 0, delta: { role: "assistant", content: r.text }, finish_reason: null }] })
  }
  send({ choices: [{ index: 0, delta: {}, finish_reason: r.tool ? "tool_calls" : "stop" }],
    usage: { prompt_tokens: r.usage, completion_tokens: 20, total_tokens: r.usage + 20 } })
  res.write("data: [DONE]\n\n")
  res.end()
}
const fake = createServer((req, res) => {
  let data = ""
  req.on("data", (c) => (data += c))
  req.on("end", () => {
    if (req.method !== "POST" || !req.url.endsWith("/chat/completions")) {
      res.writeHead(404).end()
      return
    }
    sse(res, reply(JSON.parse(data || "{}")))
  })
})
await new Promise((r) => fake.listen(0, "127.0.0.1", r))
const fakePort = fake.address().port

// --- opencode serve with the plugin and the stand-in provider ---
const work = mkdtempSync(join(tmpdir(), "ccplugin-live-"))
const project = join(work, "project")
execSync(`git init -q "${project}"`)
writeFileSync(join(project, "notes.txt"), "line one\nline two\n")
const pluginLog = join(work, "plugin.jsonl")
const overlay = join(work, "overlay.json")
writeFileSync(overlay, JSON.stringify({
  $schema: "https://opencode.ai/config.json",
  plugin: [pathToFileURL(pluginPath).href],
  model: "fixture/m",
  small_model: "fixture/m",
  provider: {
    fixture: {
      npm: "@ai-sdk/openai-compatible",
      name: "fixture",
      options: { baseURL: `http://127.0.0.1:${fakePort}/v1`, apiKey: "none" },
      models: { m: { name: "m", tool_call: true, limit: { context: 20000, output: 1000 } } },
    },
  },
}))
// An empty config home: the owner's global config (which installs the plugin
// itself since 2026-10-05) must not load a second copy or change the setup;
// only the overlay counts. opencode reads the global config from
// XDG_CONFIG_HOME/opencode.
const configHome = join(work, "config-home")
mkdirSync(join(configHome, "opencode"), { recursive: true })
const env = { ...process.env, OPENCODE_CONFIG: overlay, HOMELAB_COMPACTION_PLUGIN_LOG: pluginLog, XDG_CONFIG_HOME: configHome }
delete env.HOMELAB_COMPACTION_IDLE_CONTINUE
// A random port can be taken ("Unexpected error ServeError", 2026-10-06), so up
// to three ports are tried; only an opencode that cannot run at all is a SKIP.
let server = null
let serverOut = ""
let base = ""
function start() {
  const port = 40000 + Math.floor(Math.random() * 20000)
  serverOut = ""
  server = spawn(`${opencodeCmd} serve --port ${port} --hostname 127.0.0.1`, { cwd: project, env, shell: true, windowsHide: true })
  server.stdout.on("data", (d) => (serverOut += d))
  server.stderr.on("data", (d) => (serverOut += d))
  base = `http://127.0.0.1:${port}`
}
function killServer() {
  try {
    if (process.platform === "win32") execSync(`taskkill /T /F /PID ${server.pid}`, { stdio: "ignore" })
    else server.kill("SIGKILL")
  } catch {}
}
const q = `directory=${encodeURIComponent(project)}`
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function api(method, path, body) {
  const res = await fetch(`${base}${path}${path.includes("?") ? "&" : "?"}${q}`, {
    method, headers: { "content-type": "application/json" }, body: body ? JSON.stringify(body) : undefined,
  })
  const t = await res.text()
  return t ? JSON.parse(t) : null
}
function stop() {
  killServer()
  fake.close()
}

try {
  let up = false
  for (let attempt = 1; attempt <= 3 && !up; attempt++) {
    start()
    for (let i = 0; i < 60 && !up; i++) {
      try { await api("GET", "/session"); up = true } catch { await sleep(500) }
    }
    if (!up) killServer()
  }
  if (!up) {
    let installed = true
    try { execSync(`${opencodeCmd} --version`, { stdio: "ignore" }) } catch { installed = false }
    console.log((installed ? "FAIL" : "SKIP") + " opencode serve did not start on 3 ports: " + serverOut.slice(0, 300).replace(/\s+/g, " "))
    stop()
    process.exit(installed ? 1 : 0)
  }
  const session = await api("POST", "/session", {})
  await api("POST", `/session/${session.id}/prompt_async`, {
    parts: [{ type: "text", text: "FIXTURE-TASK: the second line of notes.txt is wrong, fix it." }],
    model: { providerID: "fixture", modelID: "m" },
  })
  // Until the model has answered the idle continue, then a few seconds more:
  // nothing else may follow.
  let messages = []
  const doneAt = { t: 0 }
  for (let i = 0; i < 240; i++) {
    await sleep(500)
    messages = (await api("GET", `/session/${session.id}/message`)) || []
    const done = messages.some((m) => m.info.role === "assistant" && m.parts.some((p) => p.type === "text" && (p.text || "").startsWith("FIXTURE-DONE")))
    if (done && !doneAt.t) doneAt.t = Date.now()
    if (doneAt.t && Date.now() - doneAt.t > 4000) break
  }
  const log = existsSync(pluginLog) ? readFileSync(pluginLog, "utf8") : ""
  const idleMsgs = messages.filter((m) => m.info.role === "user" && m.parts.some((p) => p.metadata && p.metadata.homelab_idle_continue))
  check("the plugin loaded inside opencode serve", log.includes('"message":"loaded"') && log.includes('"idleContinue":true'), true)
  check("...only the copy under test: the global config stayed out", log.includes("duplicate copy skipped"), false)
  check("the task step ran, then opencode compacted", [seen.task, seen.compaction >= 1], [1, true])
  check("...the compaction prompt carried the original request", seen.compactionHadOriginal, true)
  check("...a summary message was stored", messages.some((m) => m.info.role === "assistant" && m.info.summary === true), true)
  check("the model got the rewritten continue message, never opencode's own", [seen.rewritten >= 1, seen.unrewritten], [true, 0])
  check("after the recap-stop: exactly one idle continue stored", idleMsgs.length, 1)
  check("...its text is CONTINUE_TEXT", idleMsgs[0] && idleMsgs[0].parts.find((p) => p.type === "text").text, CONTINUE_TEXT)
  check("...the model was sent it as is, once, and finished", seen.idleContinue, 1)
  check("...logged as sent", (log.match(/"message":"sent the idle continue message"/g) || []).length, 1)
  check("...and the finished session was not continued again", log.includes('"reason":"already continued after this compaction"'), true)
  check("no unexpected model requests", seen.other, [])
} catch (e) {
  console.log("FAIL live run threw: " + (e && e.stack ? e.stack : e))
  console.log(serverOut.slice(-1500))
  failed++
} finally {
  stop()
  try { rmSync(work, { recursive: true, force: true }) } catch {}
}
process.exit(failed ? 1 : 0)
