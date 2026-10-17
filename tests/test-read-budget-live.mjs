// Live check of opencode/plugins/read-budget.js inside the REAL opencode
// (`opencode serve`), against a scripted stand-in model. Run by
// tests/test-read-budget.ps1 (node, no dependencies). The stand-in speaks the
// OpenAI chat-completions stream and plays kane-08's first move:
//   1. the task: one `read` of a ~130 KB file with no offset and no limit;
//   2. after the tool result: "FIXTURE-DONE", having recorded the result text.
// Checks: the plugin loaded in opencode; the model's tool result is clamped
// (far under read's own 50 KB cut, near the cap for a 65,536-token window, with
// read's own footer showing a later offset) and ends in the plugin's hint, which
// proves both that the before hook's mutation of output.args reached read and
// that the after hook's append reached the model; the evidence log has the
// clamp. A second read, with a window of 32,768 tokens in a second model,
// gets about half the lines. Prints "PASS name" / "FAIL name" lines; "SKIP ..."
// and exit 0 when opencode cannot be started. Exit 1 on a failure.
//
// Usage: node test-read-budget-live.mjs <plugin.js> [opencode command]
import { createServer } from "node:http"
import { spawn, execSync } from "node:child_process"
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

const pluginPath = process.argv[2]
const opencodeCmd = process.argv[3] || "opencode"
const { capChars } = await import(pathToFileURL(pluginPath).href)

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
const textOf = (content) =>
  typeof content === "string" ? content : (content || []).map((p) => (p && typeof p.text === "string" ? p.text : "")).join("\n")
const results = { m64: null, m32: null }
let project = ""
function reply(body) {
  const msgs = body.messages || []
  const hasTools = Array.isArray(body.tools) && body.tools.length > 0
  if (!hasTools) return { text: "Fixture session", usage: 50 } // the title
  const lastUser = [...msgs].reverse().find((m) => m.role === "user")
  const task = textOf(lastUser && lastUser.content)
  const key = body.model === "m32" ? "m32" : "m64"
  const last = msgs[msgs.length - 1]
  if (last && last.role === "tool") {
    results[key] = textOf(last.content)
    return { text: "FIXTURE-DONE", usage: 300 }
  }
  if (task.includes("FIXTURE-TASK")) return { tool: { name: "read", args: { filePath: join(project, "big.txt") } }, usage: 500 }
  return { text: "unexpected request", usage: 100 }
}
function sse(res, r, model) {
  const base = { id: "chatcmpl-fx", object: "chat.completion.chunk", created: 0, model }
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
    const body = JSON.parse(data || "{}")
    sse(res, reply(body), body.model)
  })
})
await new Promise((r) => fake.listen(0, "127.0.0.1", r))
const fakePort = fake.address().port

// --- opencode serve with the plugin and the stand-in provider ---
const work = mkdtempSync(join(tmpdir(), "rbplugin-live-"))
project = join(work, "project")
execSync(`git init -q "${project}"`)
// ~130 KB, 2,800 lines, like kane-08's signals.ts.
const bigText = Array.from({ length: 2800 }, (_, i) => `line ${String(i + 1).padStart(4, "0")} ${"y".repeat(36)}`).join("\n") + "\n"
writeFileSync(join(project, "big.txt"), bigText)
const pluginLog = join(work, "plugin.jsonl")
const overlay = join(work, "overlay.json")
const model = (context) => ({ name: "m", tool_call: true, limit: { context, output: 1000 } })
writeFileSync(overlay, JSON.stringify({
  $schema: "https://opencode.ai/config.json",
  plugin: [pathToFileURL(pluginPath).href],
  model: "fixture/m64",
  small_model: "fixture/m64",
  provider: {
    fixture: {
      npm: "@ai-sdk/openai-compatible",
      name: "fixture",
      options: { baseURL: `http://127.0.0.1:${fakePort}/v1`, apiKey: "none" },
      models: { m64: model(65536), m32: model(32768) },
    },
  },
}))
// An empty config home: the owner's global config (which installs both plugins
// since 2026-10-05 / 2026-10-17) must not load a second copy; only the overlay counts.
const configHome = join(work, "config-home")
mkdirSync(join(configHome, "opencode"), { recursive: true })
const env = { ...process.env, OPENCODE_CONFIG: overlay, HOMELAB_READ_BUDGET_LOG: pluginLog, XDG_CONFIG_HOME: configHome }
delete env.HOMELAB_READ_MAX_CHARS
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
async function runSession(modelID) {
  const session = await api("POST", "/session", {})
  await api("POST", `/session/${session.id}/prompt_async`, {
    parts: [{ type: "text", text: "FIXTURE-TASK: read big.txt." }],
    model: { providerID: "fixture", modelID },
  })
  for (let i = 0; i < 120; i++) {
    await sleep(500)
    const messages = (await api("GET", `/session/${session.id}/message`)) || []
    if (messages.some((m) => m.info.role === "assistant" && m.parts.some((p) => p.type === "text" && (p.text || "").startsWith("FIXTURE-DONE")))) return messages
  }
  return []
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
  const done64 = await runSession("m64")
  const done32 = await runSession("m32")
  const log = existsSync(pluginLog) ? readFileSync(pluginLog, "utf8") : ""
  const clamps = log.split("\n").filter((l) => l.includes('"message":"clamp"')).map((l) => JSON.parse(l))
  const r64 = results.m64 || ""
  const r32 = results.m32 || ""
  const cap64 = capChars(65536, {})
  const cap32 = capChars(32768, {})
  const shown = (r) => { const m = r.match(/Showing lines 1-(\d+) of (\d+)\. Use offset=(\d+) to continue/); return m ? m.slice(1).map(Number) : null }
  const hint = (r) => r.split("\n").filter((l) => l.startsWith("(read-budget:")).length

  check("the plugin loaded inside opencode serve", log.includes('"message":"loaded"'), true)
  check("...only the copy under test: the global config stayed out", log.includes("duplicate copy skipped"), false)
  check("both sessions ran to the model's answer", [done64.length > 0, done32.length > 0], [true, true])
  check("64k model: the tool result reached the model", r64.includes("<content>"), true)
  console.log(`     (64k tool result: ${r64.length} chars; cap ${cap64}; file ${bigText.length} chars)`)
  const hintLen = (r64.split("\n").filter((l) => l.startsWith("(read-budget:"))[0] || "").length
  check("...clamped far under read's own 50 KB cut", r64.length > 1000 && r64.length < 30000, true)
  check("...within the cap plus the hint", r64.length <= cap64 + hintLen + 2, true)
  // shown() = [last line shown, total lines, next offset] from read's own footer.
  const nShown = (r) => (r.match(/^\d+: /gm) || []).length
  check("...read's own footer knows the lowered limit: lines 1-N of 2800, continue at N+1",
    [shown(r64) && shown(r64)[0] === nShown(r64), shown(r64) && shown(r64)[1], shown(r64) && shown(r64)[2] === nShown(r64) + 1], [true, 2800, true])
  check("...and N is well under the 2000-line default and over 100", nShown(r64) > 100 && nShown(r64) < 1000, true)
  check("...it ends with exactly one read-budget hint, with the real numbers", [hint(r64), /read-budget: .*big\.txt is \d+ KB, 2,800 lines, more than fits/.test(r64)], [1, true])
  check("32k model: clamped too, to fewer lines than the 64k one", nShown(r32) > 0 && nShown(r32) < nShown(r64), true)
  console.log(`     (32k tool result: ${r32.length} chars; cap ${cap32})`)
  check("...within its cap plus the hint", r32.length <= cap32 + (r32.split("\n").filter((l) => l.startsWith("(read-budget:"))[0] || "").length + 2, true)
  check("the evidence log has one clamp per read, reason cap", [clamps.length, clamps.map((c) => c.reason)], [2, ["cap", "cap"]])
  check("...with the path, offset 1 and no limit asked", [clamps[0] && clamps[0].path.endsWith("big.txt"), clamps[0] && clamps[0].offset, clamps[0] && clamps[0].asked], [true, 1, null])
  check("...and the limit it set", clamps[0] && clamps[0].set, nShown(r64))
} catch (e) {
  console.log("FAIL live run threw: " + (e && e.stack ? e.stack : e))
  console.log(serverOut.slice(-1500))
  failed++
} finally {
  stop()
  try { rmSync(work, { recursive: true, force: true }) } catch {}
}
process.exit(failed ? 1 : 0)
