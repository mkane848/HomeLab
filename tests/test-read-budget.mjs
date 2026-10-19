// Unit checks for opencode/plugins/read-budget.js, run by tests/test-read-budget.ps1
// (node, no dependencies). Prints one "PASS name" / "FAIL name" line per check.
// Exit 1 on a failure. Optional argv[3] = "no-mutation" | "no-reset": a control
// that breaks one piece of the plugin (by wrapping its hooks) so the checks must fail.
import { pathToFileURL } from "node:url"
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const pluginPath = process.argv[2]
const control = process.argv[3] || ""
const mod = await import(pathToFileURL(pluginPath).href)
const { capChars, fileBudgetChars, fitLines, naturalLines, printedLength, scanFile, createHooks, fileLogger, WINDOW_LINES, MAX_CAP_CHARS } = mod

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

// Hooks the way opencode calls them: one object is both the call's args and
// the before hook's output.args (session/tools.ts L106-111).
function hooks(opts = {}) {
  const logs = []
  const h = createHooks(undefined, (m, e) => logs.push([m, e]), opts.directory || dir)
  if (control === "no-mutation") {
    const before = h["tool.execute.before"]
    h["tool.execute.before"] = async (input, output) => before(input, { args: { ...output.args } })
  }
  if (control === "no-reset") h["experimental.session.compacting"] = async () => {}
  h.logs = logs
  return h
}
async function read(h, sessionID, args, callID = Math.random().toString(36).slice(2), outputText = "OUT") {
  const a = { ...args }
  await h["tool.execute.before"]({ tool: "read", sessionID, callID }, { args: a })
  const out = { title: "t", output: outputText, metadata: {} }
  await h["tool.execute.after"]({ tool: "read", sessionID, callID, args: a }, out)
  return { args: a, out }
}
async function learn(h, sessionID, context, agent = "build") {
  await h["chat.params"]({ sessionID, agent, model: { limit: { context, output: 8192 } } }, {})
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
{
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
  const png = write("pic.png", "not really a png\n".repeat(20000))
  mkdirSync(join(dir, "sub"), { recursive: true })
  const r = [
    await read(h, "s", { filePath: join(dir, "missing.ts") }),
    await read(h, "s", { filePath: join(dir, "sub") }),
    await read(h, "s", { filePath: bin }),
    await read(h, "s", { filePath: withNul }),
    await read(h, "s", { filePath: png }),
  ]
  check("missing, directory, binary (extension), binary (NUL) and image paths are left to read", r.map((x) => [x.args.limit, x.out.output]), r.map(() => [undefined, "OUT"]))
  const odd = await h["tool.execute.before"]({ tool: "read", sessionID: "s", callID: "c" }, { args: { filePath: 5 } })
  check("a malformed call does not throw", odd, undefined)
  const other = { filePath: big }
  await h["tool.execute.before"]({ tool: "grep", sessionID: "s", callID: "g" }, { args: other })
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
  await h["experimental.session.compacting"]({ sessionID: "sb" }, { context: [] })
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
  await h["experimental.session.compacting"]({ sessionID: "B" }, { context: [] })
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

// --- the module shape opencode 1.18.34's loader needs (plugin/shared.ts) ---
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

process.exit(failed ? 1 : 0)
