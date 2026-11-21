// Unit checks for the read-budget plugin, run by tests/test-read-budget.ps1 (node,
// no dependencies), against either entrypoint:
//   - opencode/plugins/read-budget.js        the 1.x plugin ({id, server()})
//   - opencode/plugins/read-budget/index.js  the 2.x plugin ({id, setup(ctx)})
// The module's shape picks the hook calling convention; the behaviour checks are
// the same for both, then each has its own (1.x: chat.params, the system
// transform, server(); 2.x: the window from ctx.model.list(), setup(ctx), the
// result's text parts, negative offsets). Prints one "PASS name" / "FAIL name"
// line per check. Exit 1 on a failure. Optional argv[3] = "no-mutation" |
// "no-reset": a control that breaks one piece of the plugin (by wrapping its
// hooks) so the checks must fail.
import { pathToFileURL } from "node:url"
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const pluginPath = process.argv[2]
const control = process.argv[3] || ""
const mod = await import(pathToFileURL(pluginPath).href)
const { capChars, fileBudgetChars, fitLines, naturalLines, printedLength, createHooks, fileLogger, WINDOW_LINES, MAX_CAP_CHARS } = mod
const V2 = typeof (mod.default && mod.default.setup) === "function"
const DIALECT = V2 ? "v2" : "v1"
const scanFile = (path) => mod.scanFile(path, DIALECT)
console.log(`(plugin under test: opencode ${V2 ? "2.x {id, setup(ctx)}" : "1.x {id, server()}"})`)

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

const dir = mkdtempSync(join(tmpdir(), "readbudget-"))
const write = (name, text) => (writeFileSync(join(dir, name), text), join(dir, name))
// 3000 lines of 40 chars: ~125 KB, past read's own 50 KB cut.
const big = write("big.ts", Array.from({ length: 3000 }, (_, i) => `line ${String(i + 1).padStart(5, "0")} ${"x".repeat(26)}`).join("\n") + "\n")
const small = write("small.ts", "a\nb\nc\n")

// Hooks the way opencode calls them.
//   1.x: one object is both the call's args and the before hook's output.args
//        (session/tools.ts L106-111); the after hook's output.output is the text.
//   2.x: the before event's `input` is what read runs with; the after event's
//        `result.content` (text parts) is what the model gets.
// A model's window in 2.x comes from ctx.model.list(); here model id "w<n>" has
// a window of n tokens.
const windowOf = async (m) => (/^w\d+$/.test(m.id) ? Number(m.id.slice(1)) : undefined)
function hooks(opts = {}) {
  const logs = []
  const h = V2
    ? createHooks(undefined, (m, e) => logs.push([m, e]), opts.directory || dir, windowOf)
    : createHooks(undefined, (m, e) => logs.push([m, e]), opts.directory || dir)
  if (control === "no-mutation") {
    if (V2) {
      const before = h.before
      h.before = async (event) => before({ ...event, input: { ...event.input } })
    } else {
      const before = h["tool.execute.before"]
      h["tool.execute.before"] = async (input, output) => before(input, { args: { ...output.args } })
    }
  }
  if (control === "no-reset") {
    if (V2) h.compaction = async () => {}
    else h["experimental.session.compacting"] = async () => {}
  }
  h.logs = logs
  return h
}
// args use the 1.x key filePath; for 2.x it becomes `path`. Returns the args the
// read ran with (as filePath/offset/limit) and the text the model got.
async function read(h, sessionID, args, callID = Math.random().toString(36).slice(2), outputText = "OUT") {
  if (!V2) {
    const a = { ...args }
    await h["tool.execute.before"]({ tool: "read", sessionID, callID }, { args: a })
    const out = { title: "t", output: outputText, metadata: {} }
    await h["tool.execute.after"]({ tool: "read", sessionID, callID, args: a }, out)
    return { args: a, out }
  }
  const { filePath, ...rest } = args
  const input = { path: filePath, ...rest }
  const base = { tool: "read", sessionID, agent: "build", messageID: "msg_fx", id: callID }
  await h.before({ ...base, input })
  const after = { ...base, input, status: "completed", result: { output: { type: "text" }, content: [{ type: "text", text: outputText }], metadata: {} } }
  await h.after(after)
  const { path, ...back } = input
  return { args: { filePath: path, ...back }, out: { output: mod.resultText(after.result.content) }, event: after }
}
// A raw before call, for malformed input: `args` as the 1.x args object.
async function rawBefore(h, tool, sessionID, callID, args) {
  if (!V2) return h["tool.execute.before"]({ tool, sessionID, callID }, { args })
  const { filePath, ...rest } = args
  const input = { path: filePath, ...rest }
  const r = await h.before({ tool, sessionID, id: callID, input })
  if (input.limit !== undefined) args.limit = input.limit
  return r
}
async function learn(h, sessionID, context, agent = "build") {
  if (V2) await h.context({ sessionID, agent, model: { providerID: "fx", id: `w${context}` }, system: [], messages: [], tools: {}, options: {} })
  else await h["chat.params"]({ sessionID, agent, model: { limit: { context, output: 8192 } } }, {})
}
async function compact(h, sessionID) {
  if (V2) await h.compaction({ sessionID, agent: "build", model: { providerID: "fx", id: "w65536" }, system: [], messages: [] })
  else await h["experimental.session.compacting"]({ sessionID }, { context: [] })
}

// --- the arithmetic ---
check("cap at 32,768 tokens", capChars(32768, {}), 8650)
check("cap at 65,536 tokens", capChars(65536, {}), 17301)
check("cap at 200,000 tokens is the 50 KB read cap, no tighter", capChars(200000, {}), MAX_CAP_CHARS)
check("cap with an unknown window falls back to 65,536", capChars(undefined, {}), 17301)
check("...also for a zero or junk limit", [capChars(0, {}), capChars("x", {})], [17301, 17301])
check("HOMELAB_READ_MAX_CHARS replaces the computed cap", capChars(65536, { HOMELAB_READ_MAX_CHARS: "5000" }), 5000)
check("...a junk value is ignored", capChars(65536, { HOMELAB_READ_MAX_CHARS: "lots" }), 17301)
check("per-file budget at 65,536 tokens", fileBudgetChars(65536), 54067)
check("per-file budget with an unknown window", fileBudgetChars(null), 54067)

// --- how many lines fit: the printed line is "<n>: <line>\n" ---
check("printed length counts the number prefix and the newline", printedLength(7, "abc"), 1 + 2 + 3 + 1)
check("...a 2-digit number is one char wider", printedLength(10, "abc"), 2 + 2 + 3 + 1)
check("...a line over 2000 chars is cut and gets read's suffix", printedLength(1, "y".repeat(5000)), 1 + 2 + 2000 + "... (line truncated to 2000 chars)".length + 1)
{
  const lines = Array.from({ length: 50 }, () => "0123456789") // each 1+2+10+1 = 14 for 1-9, 15 for 10-50
  check("fitLines stops at the budget", fitLines(lines, 1, 100), 7) // 9 * 14 > 100; 7 * 14 = 98
  check("...counts from the offset", fitLines(lines, 10, 100), 6) // 15 each: 6 * 15 = 90, 7 * 15 = 105
  check("...at least one line however long", fitLines(["z".repeat(9000)], 1, 10), 1)
  check("...never more than max", fitLines(lines, 1, 100000, 3), 3)
  check("naturalLines: read's own 2000-line default", naturalLines(Array.from({ length: 5000 }, () => "a"), 1, undefined), 2000)
  check("...the caller's smaller limit", naturalLines(lines, 1, 5), 5)
  check("...the end of the file", naturalLines(lines, 48, undefined), 3)
}

// --- the before hook ---
const CAP64 = capChars(65536, {})
{
  const h = hooks()
  await learn(h, "s64", 65536)
  const r = await read(h, "s64", { filePath: big })
  const lines = scanFile(big).lines
  const expected = fitLines(lines, 1, CAP64 - big.length - mod.FRAME_CHARS)
  check("a big file: limit set to the lines that fit the 64k cap", r.args.limit, expected)
  check("...whose printed lines fit the cap", Array.from({ length: r.args.limit }, (_, i) => printedLength(i + 1, lines[i])).reduce((a, b) => a + b, 0) <= CAP64, true)
  check("...and not one line fewer than needed (the next line would not fit)",
    Array.from({ length: r.args.limit + 1 }, (_, i) => printedLength(i + 1, lines[i])).reduce((a, b) => a + b, 0) + big.length + mod.FRAME_CHARS > CAP64, true)
  check("...the hint is appended with the real numbers", r.out.output.split("\n").pop(),
    `(read-budget: ${big} is ${Math.round(scanFile(big).size / 1024)} KB, 3,000 lines, more than fits in your context beside the rest of the work. Use grep to find what you need, then read just those lines with offset and limit.)`)
  check("...one clamp counted and logged", [h.state.clamps, h.logs.length, h.logs[0][0]], [1, 1, "clamp"])
  check("...the log line names reason, offset, asked, set and chars", [h.logs[0][1].reason, h.logs[0][1].offset, h.logs[0][1].asked, h.logs[0][1].set, h.logs[0][1].chars, h.logs[0][1].sessionID, h.logs[0][1].path],
    ["cap", 1, null, expected, 3, "s64", big])
}
{
  const h = hooks()
  await learn(h, "s32", 32768)
  const a = await read(h, "s32", { filePath: big })
  const h2 = hooks()
  await learn(h2, "s64", 65536)
  const b = await read(h2, "s64", { filePath: big })
  check("a 32k model gets about half the lines of a 64k one", a.args.limit < b.args.limit && a.args.limit > b.args.limit / 3, true)
  const h3 = hooks()
  await learn(h3, "s200", 200000)
  const c = await read(h3, "s200", { filePath: big })
  check("a 200k model: the 50 KB cap, which read's own byte cut already applies (no limit set, no hint)", [c.args.limit, c.out.output], [undefined, "OUT"])
}
{
  const h = hooks()
  const r = await read(h, "unknown", { filePath: big })
  check("a session whose model was never seen: the 64k default", r.args.limit, fitLines(scanFile(big).lines, 1, CAP64 - big.length - mod.FRAME_CHARS))
}
if (!V2) {
  const h = hooks()
  await h["experimental.chat.system.transform"]({ sessionID: "sx", model: { limit: { context: 32768 } } }, { system: [] })
  await h["experimental.chat.system.transform"]({ sessionID: "sx", model: { limit: { context: 4096 } } }, { system: [] })
  check("the system transform fills a gap but never overwrites", h.state.contexts.get("sx"), 32768)
  await learn(h, "sx", 65536)
  check("chat.params overwrites", h.state.contexts.get("sx"), 65536)
  await learn(h, "sx", 2048, "title")
  check("...but not for the title agent's small model", h.state.contexts.get("sx"), 65536)
}
{
  const h = hooks()
  await learn(h, "s", 65536)
  const r = await read(h, "s", { filePath: big, limit: 30 })
  check("the caller's smaller limit is respected: nothing clamped", [r.args.limit, r.out.output], [30, "OUT"])
  const r2 = await read(h, "s", { filePath: big, limit: 100000 })
  check("a larger limit is lowered to the cap", r2.args.limit < 600, true)
  const r3 = await read(h, "s", { filePath: big, offset: 2000 })
  check("an offset: counted from there", r3.args.limit > 0 && r3.args.limit < 600, true)
  check("...and logged with it", h.logs.at(-1)[1].offset, 2000)
  const r4 = await read(h, "s", { filePath: small })
  check("a small file is untouched", [r4.args.limit, r4.out.output], [undefined, "OUT"])
  const r5 = await read(h, "s", { filePath: "big.ts" })
  check("a relative path resolves against the project directory", r5.args.limit > 0, true)
  const r6 = await read(h, "s", { filePath: big, offset: 99999 })
  check("an offset past the end is read's to refuse", r6.args.limit, undefined)
}
{
  const h = hooks()
  await learn(h, "s", 65536)
  const bin = write("blob.bin", Buffer.alloc(200000, 1))
  const withNul = write("nul.txt", "abc\0def\n".repeat(30000))
  // An image by its name (1.x) and by its magic bytes (2.x), text after them.
  const png = write("pic.png", Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), Buffer.from("not really a png\n".repeat(20000))]))
  mkdirSync(join(dir, "sub"), { recursive: true })
  const r = [
    await read(h, "s", { filePath: join(dir, "missing.ts") }),
    await read(h, "s", { filePath: join(dir, "sub") }),
    await read(h, "s", { filePath: bin }),
    await read(h, "s", { filePath: withNul }),
    await read(h, "s", { filePath: png }),
  ]
  check("missing, directory, binary (extension), binary (NUL) and image paths are left to read", r.map((x) => [x.args.limit, x.out.output]), r.map(() => [undefined, "OUT"]))
  const odd = await rawBefore(h, "read", "s", "c", { filePath: 5 })
  check("a malformed call does not throw", odd, undefined)
  const other = { filePath: big }
  await rawBefore(h, "grep", "s", "g", other)
  check("other tools are not touched", other.limit, undefined)
}
{
  // Lines longer than 2000 chars count as 2000 plus read's suffix.
  const h = hooks()
  await learn(h, "s", 65536)
  const long = write("long.ts", Array.from({ length: 200 }, () => "y".repeat(3000)).join("\n") + "\n")
  const r = await read(h, "s", { filePath: long })
  const per = printedLength(100, "y".repeat(3000))
  check("200 lines of 3000 chars: counted as cut lines, not 3000", r.args.limit, Math.floor((CAP64 - long.length - mod.FRAME_CHARS) / per) )
}
{
  // CRLF and a file with no final newline split the way read splits them.
  const crlf = write("crlf.ts", "one\r\ntwo\r\nthree")
  check("scanFile: CRLF, no final newline", scanFile(crlf).lines, ["one", "two", "three"])
  // A lone \r and a BOM: 1.x splits on \r and keeps the BOM; 2.x splits on \n
  // only, drops one trailing \r per line and the BOM.
  const cr = write("cr.ts", String.fromCharCode(0xfeff) + "a\rb\nc\r\r\n")
  check(`scanFile (${DIALECT}): a lone CR and a BOM, as this read splits them`, scanFile(cr).lines, V2 ? ["a\rb", "c\r"] : [String.fromCharCode(0xfeff) + "a", "b", "c", ""])
  check("scanFile: a final newline leaves no empty last line", scanFile(small).lines, ["a", "b", "c"])
  check("scanFile: missing", scanFile(join(dir, "nope")), null)
}

// --- the per-file budget ---
{
  const h = hooks()
  await learn(h, "sb", 65536)
  const budget = fileBudgetChars(65536)
  // The first read serves a good part of the budget; two more spend it.
  const first = await read(h, "sb", { filePath: big }, "c1", "x".repeat(20000))
  check("under budget: a cap clamp", h.logs.at(-1)[1].reason, "cap")
  await read(h, "sb", { filePath: big, offset: 500 }, "c2", "x".repeat(20000))
  const third = await read(h, "sb", { filePath: big, offset: 1000 }, "c3", "x".repeat(20000))
  check("served so far is past the budget", 20000 * 3 > budget, true)
  const fourth = await read(h, "sb", { filePath: big, offset: 1500 }, "c4", "x")
  check("a spent file: reads shrink to the 100-line window", fourth.args.limit, WINDOW_LINES)
  check("...reason 'budget'", h.logs.at(-1)[1].reason, "budget")
  check("...the hint says the budget is spent", fourth.out.output.split("\n").pop().includes("has already used its read budget"), true)
  check("...and still names grep", fourth.out.output.includes("Use grep"), true)
  const other = await read(h, "sb", { filePath: small }, "c5")
  check("...another (small) file in the session is unaffected", [other.args.limit, other.out.output], [undefined, "OUT"])
  const big2 = write("big2.ts", Array.from({ length: 3000 }, (_, i) => `row ${i} ${"z".repeat(30)}`).join("\n") + "\n")
  const fresh = await read(h, "sb", { filePath: big2 }, "c6")
  check("...nor is another big file (own budget): the cap clamp, more than a window", fresh.args.limit > WINDOW_LINES, true)
  const small100 = await read(h, "sb", { filePath: big, offset: 2950 }, "c7")
  check("a spent file's read that already fits the window is not clamped or hinted", [small100.args.limit, small100.out.output], [undefined, "OUT"])
  const asked = await read(h, "sb", { filePath: big, limit: 40 }, "c8")
  check("a spent file with a smaller caller limit keeps it", asked.args.limit, 40)
  await compact(h, "sb")
  const after = await read(h, "sb", { filePath: big, offset: 1500 }, "c9")
  check("after a compaction the budget is fresh: back to the cap clamp", [after.args.limit > WINDOW_LINES, h.logs.at(-1)[1].reason], [true, "cap"])
}
{
  // Two sessions are kept apart.
  const h = hooks()
  await learn(h, "A", 65536)
  await learn(h, "B", 65536)
  for (let i = 0; i < 4; i++) await read(h, "A", { filePath: big, offset: 1 + i * 600 }, `a${i}`, "x".repeat(20000))
  const a = await read(h, "A", { filePath: big, offset: 2000 }, "a9")
  const b = await read(h, "B", { filePath: big, offset: 2000 }, "b9")
  check("session A spent the file; session B has not", [a.args.limit, b.args.limit > WINDOW_LINES], [WINDOW_LINES, true])
  await compact(h, "B")
  const a2 = await read(h, "A", { filePath: big, offset: 2100 }, "a10")
  check("compacting B does not reset A", a2.args.limit, WINDOW_LINES)
}
{
  // A 32k session's budget is smaller than a 64k one's.
  const h = hooks()
  await learn(h, "S", 32768)
  for (let i = 0; i < 3; i++) await read(h, "S", { filePath: big, offset: 1 + i * 300 }, `s${i}`, "x".repeat(10000))
  const r = await read(h, "S", { filePath: big, offset: 2000 }, "s9")
  check("32k session: 30k chars served spends its 27k budget in three reads", r.args.limit, WINDOW_LINES)
}

// --- off, override ---
{
  process.env.HOMELAB_READ_MAX_CHARS = "off"
  const h = hooks()
  await learn(h, "o", 65536)
  const r = await read(h, "o", { filePath: big })
  delete process.env.HOMELAB_READ_MAX_CHARS
  check("HOMELAB_READ_MAX_CHARS=off: no clamp, no hint, no log", [r.args.limit, r.out.output, h.logs.length], [undefined, "OUT", 0])
  process.env.HOMELAB_READ_MAX_CHARS = "3000"
  const h2 = hooks()
  await learn(h2, "o", 65536)
  const r2 = await read(h2, "o", { filePath: big })
  delete process.env.HOMELAB_READ_MAX_CHARS
  check("a numeric HOMELAB_READ_MAX_CHARS tightens the cap", r2.args.limit < 100 && r2.args.limit > 40, true)
}

// --- the log ---
{
  const logFile = join(dir, "log.jsonl")
  const log = fileLogger(logFile)
  const h = createHooks(undefined, log, dir)
  await learn(h, "L", 65536)
  const r = await read(h, "L", { filePath: big, offset: 3 })
  const lines = readFileSync(logFile, "utf8").trim().split("\n").map((l) => JSON.parse(l))
  check("one JSON line per clamp, with time, session, path, offset, limits, reason, chars",
    [lines.length, lines[0].message, typeof lines[0].time, lines[0].sessionID, lines[0].path, lines[0].offset, lines[0].asked, lines[0].set, lines[0].reason, lines[0].chars],
    [1, "clamp", "string", "L", big, 3, null, r.args.limit, "cap", 3])
  check("a log path that cannot be written does not throw", (fileLogger(join(logFile, "no", "such.jsonl"))("x", {}), true), true)
  check("no log path: no logging, no throw", (fileLogger(undefined)("x", {}), true), true)
}

// --- 1.x only: the module shape opencode 1.18.34's loader needs (plugin/shared.ts) ---
if (!V2) {
  check("default export has a string id", typeof mod.default.id, "string")
  check("default export has server()", typeof mod.default.server, "function")
  {
    const logFile = join(dir, "server.jsonl")
    process.env.HOMELAB_READ_BUDGET_LOG = logFile
    const hs = await mod.default.server({ directory: join(dir, "p1") })
    delete process.env.HOMELAB_READ_BUDGET_LOG
    check("server() returns the five hooks", Object.keys(hs).sort(),
      ["chat.params", "experimental.chat.system.transform", "experimental.session.compacting", "tool.execute.after", "tool.execute.before"])
    check("server() logs 'loaded' to HOMELAB_READ_BUDGET_LOG", readFileSync(logFile, "utf8").includes('"message":"loaded"'), true)
    check("a second copy for the same directory: no hooks", Object.keys(await mod.default.server({ directory: join(dir, "p1") })).length, 0)
    check("...a copy for another directory still loads", Object.keys(await mod.default.server({ directory: join(dir, "p2") })).length, 5)
    check("no log variable, no input: loads without throwing", typeof (await mod.default.server({})), "object")
    // The harness records these two fields from this line (readBudget.off, .capOverride).
    const loaded1 = JSON.parse(readFileSync(logFile, "utf8").trim().split("\n")[0])
    check("...the loaded line says off false, capOverride null by default", [loaded1.off, loaded1.capOverride], [false, null])
    const offLog = join(dir, "server-off.jsonl")
    process.env.HOMELAB_READ_BUDGET_LOG = offLog
    process.env.HOMELAB_READ_MAX_CHARS = "off"
    await mod.default.server({ directory: join(dir, "p3") })
    delete process.env.HOMELAB_READ_BUDGET_LOG
    delete process.env.HOMELAB_READ_MAX_CHARS
    const loadedOff = JSON.parse(readFileSync(offLog, "utf8").trim().split("\n")[0])
    check("...with HOMELAB_READ_MAX_CHARS=off it says off true, capOverride 'off'", [loadedOff.message, loadedOff.off, loadedOff.capOverride], ["loaded", true, "off"])
  }
}

// --- 2.x only: what the hooks see in opencode 2.3.2 ---
if (V2) {
  const { resultText, withLine, modelLookup } = mod
  // The window comes from ctx.model.list() (2.3.2 lists the config's own
  // providers once the location's config has loaded); unknown -> 64k.
  let listCalls = 0
  let listed = [{ providerID: "fx", id: "big", limit: { context: 200000, output: 1000 } }]
  const lookup = modelLookup({ list: async () => (listCalls++, { data: listed }) })
  check("modelLookup: limit.context of the listed model", await lookup({ providerID: "fx", id: "big" }), 200000)
  check("...not listed yet: undefined", await lookup({ providerID: "fx", id: "late" }), undefined)
  listed = [...listed, { providerID: "fx", id: "late", limit: { context: 32768 } }]
  check("...listed later: found on the next call (the list is re-read on a miss)", await lookup({ providerID: "fx", id: "late" }), 32768)
  const calls = listCalls
  await lookup({ providerID: "fx", id: "big" })
  check("...a known model does not re-read the list", listCalls, calls)
  check("...a list() that throws is a miss, not an error", await modelLookup({ list: async () => { throw new Error("x") } })({ providerID: "a", id: "b" }), undefined)
  {
    const h = hooks()
    await learn(h, "sx", 32768)
    check("the context hook learns the session's window", h.state.contexts.get("sx"), 32768)
    await learn(h, "sx", 2048, "title")
    check("...but not from the title agent's small model", h.state.contexts.get("sx"), 32768)
    await h.context({ sessionID: "sx", agent: "build", model: { providerID: "fx", id: "unknown" } })
    check("...an unknown model keeps what it had", h.state.contexts.get("sx"), 32768)
    await learn(h, "sx", 65536)
    check("...a model switch overwrites", h.state.contexts.get("sx"), 65536)
  }
  {
    const h = hooks()
    await learn(h, "n", 65536)
    const tail = await read(h, "n", { filePath: big, offset: -2500 })
    check("a negative offset (2.x reads from the end): clamped from line 501", [tail.args.limit, h.logs.at(-1)[1].offset],
      [fitLines(scanFile(big).lines, 501, CAP64 - big.length - mod.FRAME_CHARS), -2500])
    const short = await read(h, "n", { filePath: big, offset: -50 })
    check("...a short tail is left alone", short.args.limit, undefined)
    const zero = await read(h, "n", { filePath: big, limit: 0 })
    check("limit 0 is read's default (2000): clamped", zero.args.limit > 100 && zero.args.limit < 600, true)
    const home = await read(h, "n", { filePath: "~/no-such-read-budget-file.ts" })
    check("a ~/ path resolves to the home directory (missing there: left to read)", home.args.limit, undefined)
    const r = await read(h, "n", { filePath: big }, "call_e")
    check("the hint is appended to the last text part, not a new part", [r.event.result.content.length, r.event.result.content[0].text.endsWith(")")], [1, true])
    check("...output and metadata are kept", [r.event.result.output.type, typeof r.event.result.metadata], ["text", "object"])
    // A failed read: no hint, no clamp counted, the pending entry dropped.
    const input = { path: big }
    await h.before({ tool: "read", sessionID: "n", id: "call_f", input })
    const failedEv = { tool: "read", sessionID: "n", id: "call_f", input, status: "error", error: { message: "boom" } }
    const clampsBefore = h.state.clamps
    await h.after(failedEv)
    check("a failed read: no result added, no clamp counted, nothing left pending", [failedEv.result, h.state.clamps, h.state.pending.size], [undefined, clampsBefore, 0])
    // The same call id in two sessions are two calls.
    const i1 = { path: big }
    const i2 = { path: small }
    await h.before({ tool: "read", sessionID: "n", id: "same", input: i1 })
    await h.before({ tool: "read", sessionID: "m", id: "same", input: i2 })
    const e2 = { tool: "read", sessionID: "m", id: "same", input: i2, status: "completed", result: { content: [{ type: "text", text: "OUT" }] } }
    await h.after(e2)
    check("...a call id is per session: the other session's small read gets no hint", resultText(e2.result.content), "OUT")
  }
  check("resultText: a string or the text parts", [resultText("ab"), resultText([{ type: "text", text: "a" }, { type: "file", uri: "x" }, { type: "text", text: "b" }]), resultText(undefined)], ["ab", "ab", ""])
  check("withLine: onto a string, the last text part, or a new part", [withLine("a", "H"), withLine([{ type: "text", text: "a" }, { type: "file" }], "H"), withLine([], "H")],
    ["a\nH", [{ type: "text", text: "a\nH" }, { type: "file" }], [{ type: "text", text: "H" }]])
  {
    // 2.x read: a NUL anywhere makes it refuse the file; media by magic bytes,
    // not by name; text is text whatever the extension.
    const late = write("late-nul.ts", "x".repeat(10000) + "\n" + "y\0\n")
    const named = write("named.png", "plain text in a .png\n".repeat(5000))
    check("2.x: a NUL past the first 4 KB still means binary", scanFile(late), null)
    check("2.x: a .png name with text inside is text", scanFile(named) && scanFile(named).lines.length, 5000)
  }
}

// --- 2.x only: the module shape and setup(ctx) ---
if (V2) {
  check("default export has a string id", typeof mod.default.id, "string")
  check("default export has setup()", typeof mod.default.setup, "function")
  // A stand-in ctx: records each hook registration, as 2.3.2's ctx does.
  const fakeCtx = (directory, models = []) => {
    const reg = []
    const disposed = []
    const hook = (kind) => async (name, cb) => {
      reg.push([kind, name, cb])
      return { dispose: async () => disposed.push(`${kind}:${name}`) }
    }
    return {
      reg, disposed,
      location: { directory },
      options: {},
      model: { list: async () => ({ data: models }) },
      tool: { hook: hook("tool") },
      session: { hook: hook("session") },
    }
  }
  const logFile = join(dir, "setup.jsonl")
  process.env.HOMELAB_READ_BUDGET_LOG = logFile
  const c1 = fakeCtx(join(dir, "q1"), [{ providerID: "fx", id: "m32", limit: { context: 32768 } }])
  const cleanup = await mod.default.setup(c1)
  delete process.env.HOMELAB_READ_BUDGET_LOG
  check("setup() registers context, execute.before, execute.after and compaction", c1.reg.map(([k, n]) => `${k}:${n}`).sort(),
    ["session:compaction", "session:context", "tool:execute.after", "tool:execute.before"])
  check("setup() logs 'loaded' to HOMELAB_READ_BUDGET_LOG", readFileSync(logFile, "utf8").includes('"message":"loaded"'), true)
  const loaded1 = JSON.parse(readFileSync(logFile, "utf8").trim().split("\n")[0])
  check("...the loaded line says off false, capOverride null by default", [loaded1.off, loaded1.capOverride], [false, null])
  {
    // The registered callbacks, end to end: the window from ctx.model.list().
    const cb = Object.fromEntries(c1.reg.map(([, n, f]) => [n, f]))
    await cb.context({ sessionID: "e2e", agent: "build", model: { providerID: "fx", id: "m32" } })
    const input = { path: big }
    await cb["execute.before"]({ tool: "read", sessionID: "e2e", id: "c1", input })
    check("...the registered hooks clamp with the window from ctx.model.list() (32k)", input.limit,
      fitLines(scanFile(big).lines, 1, capChars(32768, {}) - big.length - mod.FRAME_CHARS))
    const ev = { tool: "read", sessionID: "e2e", id: "c1", input, status: "completed", result: { content: [{ type: "text", text: "OUT" }] } }
    await cb["execute.after"](ev)
    check("...and the after hook's new result carries the hint", mod.resultText(ev.result.content).split("\n").pop().startsWith("(read-budget: "), true)
  }
  const c2 = fakeCtx(join(dir, "q1"))
  check("a second copy for the same directory registers nothing", [await mod.default.setup(c2), c2.reg.length], [undefined, 0])
  const c3 = fakeCtx(join(dir, "q2"))
  const cleanup3 = await mod.default.setup(c3)
  check("...a copy for another directory still registers", c3.reg.length, 4)
  check("setup() returns a cleanup function", typeof cleanup, "function")
  await cleanup()
  check("...which disposes its registrations", c1.disposed.length, 4)
  const c4 = fakeCtx(join(dir, "q1"))
  await mod.default.setup(c4)
  check("...and lets a reload of the same directory register again", c4.reg.length, 4)
  await cleanup3()
  check("no log variable, a bare ctx: loads without throwing", typeof (await mod.default.setup(fakeCtx(join(dir, "q3")))), "function")
  const offLog = join(dir, "setup-off.jsonl")
  process.env.HOMELAB_READ_BUDGET_LOG = offLog
  process.env.HOMELAB_READ_MAX_CHARS = "off"
  await mod.default.setup(fakeCtx(join(dir, "q4")))
  delete process.env.HOMELAB_READ_BUDGET_LOG
  delete process.env.HOMELAB_READ_MAX_CHARS
  const loadedOff = JSON.parse(readFileSync(offLog, "utf8").trim().split("\n")[0])
  check("...with HOMELAB_READ_MAX_CHARS=off it says off true, capOverride 'off'", [loadedOff.message, loadedOff.off, loadedOff.capOverride], ["loaded", true, "off"])
}

process.exit(failed ? 1 : 0)
