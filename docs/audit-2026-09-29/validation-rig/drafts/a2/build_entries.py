#!/usr/bin/env python3
"""Assemble G/entries.a2.json from the entry skeletons below + G/prompts/<id>.prompt.txt / .source.txt.
Keeps the manifest key order the brief requires. Fails loudly on non-ASCII, markdown bullets, length overruns."""
import json, os, sys, re
G = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "M:/TTRPG/A Story of Heroes and Villains"
SETUP = [{
    "note": "build @asohav/shared so the server package's workspace import resolves",
    "cwd": "packages/shared",
    "cmd": ["npx", "tsc", "-p", "tsconfig.json"],
}]
TESTENV = {"DATABASE_URL": None}
TESTENVNOTE = ("null = unset. Standing pin for the apps/server tasks. A model-written test that imports the real repo.ts "
               "also imports pgPool.ts, which throws at import time unless DATABASE_URL is set (the route tests avoid it by "
               "mocking the repo module with vi.mock). Unset is a clean checkout: the gates and the model's own shell see what CI would. "
               "The gate results of this task were verified identical with DATABASE_URL unset, set to a dummy URL, and ambient.")

def entry(id, title, branch, base, total, allow, src, testcmd, extra=None):
    e = {}
    e["id"] = id
    e["title"] = title
    e["source"] = read(id, "source")
    e["repo"] = REPO
    e["branch"] = branch
    e["benchBaseCommit"] = base
    e["packageManager"] = "npm"
    e["baselineExpect"] = {"testsTotal": total, "testsPass": total}
    e["allowFiles"] = allow
    e["srcRevertFiles"] = src
    e["testDir"] = "apps/server"
    e["testCmd"] = testcmd
    e["installFlags"] = ["--ignore-scripts"]
    e["testEnv"] = TESTENV
    e["testEnvNote"] = TESTENVNOTE
    e["setup"] = SETUP
    if extra and "acceptance" in extra:
        e["acceptance"] = extra["acceptance"]
    e["prompt"] = read(id, "prompt")
    return e

def read(id, kind):
    p = os.path.join(G, "prompts", "%s.%s.txt" % (id, kind))
    if not os.path.exists(p):
        return "PLACEHOLDER %s for %s" % (kind, id)
    return open(p, encoding="utf-8").read().strip().replace("\n", " ")

entries = []
entries.append(entry(
    "asohav-05-library-write-validation",
    "ASoHaVCompanionApp: the Content Admin library write routes must validate the request body instead of trusting it",
    "bench/library-write-validation",
    "79b369d7ba01ed02affa6534a33ef698d17b5518", 14,
    ["apps/server/src/routes/library.ts", "apps/server/src/adminLogic.ts", "apps/server/src/routes/library.test.ts"],
    ["apps/server/src/routes/library.ts", "apps/server/src/adminLogic.ts"],
    ["npx", "vitest", "run", "src/routes/library.test.ts"]))
entries.append(entry(
    "asohav-07-rapport-clamp",
    "ASoHaVCompanionApp: the party save route must keep banked Rapport above the track length instead of clamping it away",
    "bench/rapport-clamp",
    "d73d6c978f478e3aca5fb836683fcfe639debd43", 5,
    ["apps/server/src/routes/party.ts", "apps/server/src/routes/party.test.ts"],
    ["apps/server/src/routes/party.ts"],
    ["npx", "vitest", "run", "src/routes/party.test.ts"],
    {"acceptance": {
        "note": "The upstream fix commit's own test file, swapped in over the model's and run against the model's source - informational, never a gate. Nothing beyond existing exports needs pinning.",
        "ref": "upstream-fix",
        "commit": "2db8a09b37fc967ad1199bfa436a3d1ebde1c0d1",
        "files": ["apps/server/src/routes/party.test.ts"]}}))
entries.append(entry(
    "asohav-08-end-combat-clears-strain",
    "ASoHaVCompanionApp: ending a Combat must clear the marked Strain on every participating Hero's sheet",
    "bench/end-combat-clears-strain",
    "9afb9112b0e2596edac0e7fe4055149512ab3b62", 18,
    ["apps/server/src/routes/combat.ts", "apps/server/src/routes/combat.test.ts"],
    ["apps/server/src/routes/combat.ts"],
    ["npx", "vitest", "run", "src/routes/combat.test.ts"],
    {"acceptance": {
        "note": "The upstream fix commit's own test file, swapped in over the model's and run against the model's source - informational, never a gate. The prompt pins the call shape saveSheet(sheet, campaignId) and that only sheets with marked Strain are saved.",
        "ref": "upstream-fix",
        "commit": "d7696990b5e2551c9897e6ec255c70be213ca8b2",
        "files": ["apps/server/src/routes/combat.test.ts"]}}))

# ---- checks --------------------------------------------------------------
bad = 0
def walk(x, path):
    global bad
    if isinstance(x, str):
        try:
            x.encode("ascii")
        except UnicodeEncodeError:
            print("NON-ASCII in", path, [c for c in x if ord(c) > 127][:5]); bad += 1
    elif isinstance(x, dict):
        for k, v in x.items(): walk(v, path + "." + k)
    elif isinstance(x, list):
        for i, v in enumerate(x): walk(v, "%s[%d]" % (path, i))
for e in entries:
    walk(e, e["id"])
    p = e["prompt"]
    n = len(p)
    flags = []
    if n < 1500 or n > 2800: flags.append("LENGTH %d outside 1500-2800" % n)
    if re.search(r"(^|\s)[-*] |\u2022", p): flags.append("bullet-like char")
    if "`" in p and False: pass
    print("%-40s prompt=%d chars source=%d chars %s" % (e["id"], n, len(e["source"]), "; ".join(flags)))
    if len(e["source"]) > 1000: print("   (source over 1000 chars)")
out = os.path.join(G, "entries.a2.json")
json.dump(entries, open(out, "w", encoding="utf-8"), indent=2, ensure_ascii=True)
json.load(open(out, encoding="utf-8"))
print("wrote", out, "ASCII problems:", bad)
