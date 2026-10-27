#!/usr/bin/env python3
"""Assemble entries.a1.json from structured data + prompts/<id>.txt + src-text/<id>.source.txt.
Keeps key order required by the brief, checks ASCII-only, prints prompt/source lengths."""
import json, os, sys
G = os.path.dirname(os.path.abspath(__file__))
REPO = "M:/TTRPG/A Story of Heroes and Villains"
KEY_ORDER = ["id","title","source","repo","branch","benchBaseCommit","packageManager","baselineExpect","allowFiles",
             "srcRevertFiles","testDir","testCmd","installFlags","testEnv","testEnvNote","setup","acceptance","prompt"]

def read(path, default=""):
    p = os.path.join(G, path)
    if not os.path.exists(p):
        return default
    return open(p, encoding="utf-8").read().strip().replace("\n", " ")

SPEC = [
  dict(id="asohav-03-glossary-depth-flatten",
       title="ASoHaVCompanionApp: a glossary definition nested one bubble deep must render as plain text, with explicit [display][id] tags flattened to their display text instead of leaking raw brackets",
       repo=REPO, branch="bench/glossary-depth-flatten",
       benchBaseCommit="5c891936847a844bb23dd74b02aa1fa6f1525f84", packageManager="npm",
       baselineExpect={"testsTotal":20,"testsPass":20},
       allowFiles=["packages/shared/src/glossary.ts","packages/shared/src/glossary.test.ts"],
       srcRevertFiles=["packages/shared/src/glossary.ts"],
       testDir="packages/shared", testCmd=["npx","vitest","run","src/glossary.test.ts"], installFlags=["--ignore-scripts"],
       acceptance=dict(ref="upstream-fix", commit="3003542385e2e83a862ff648b69ea0a8f9873da6", files=["packages/shared/src/glossary.test.ts"]),
       acceptance_note_file="src-text/asohav-03-glossary-depth-flatten.acceptance-note.txt"),
  dict(id="asohav-04-neutral-status-polarity",
       title="ASoHaVCompanionApp: a Neutral Status must not count as a hindering roll modifier or trigger Subdued",
       repo=REPO, branch="bench/neutral-status-polarity",
       benchBaseCommit="f15a58cb9ef29c3b511caa0d88949a7b10686874", packageManager="npm",
       baselineExpect={"testsTotal":22,"testsPass":22},
       allowFiles=["packages/shared/src/engine.ts","packages/shared/src/engine.test.ts"],
       srcRevertFiles=["packages/shared/src/engine.ts"],
       testDir="packages/shared", testCmd=["npx","vitest","run","src/engine.test.ts"], installFlags=["--ignore-scripts"],
       acceptance=dict(ref="upstream-fix", commit="2729b58616447dc6ff6ede2cebdae2641d4e7c47", files=["packages/shared/src/engine.test.ts"]),
       acceptance_note_file="src-text/asohav-04-neutral-status-polarity.acceptance-note.txt"),
  dict(id="asohav-06-bond-cap-setting",
       title="ASoHaVCompanionApp: the Bond cap must follow GameSettings.BondTrackLength instead of a hardcoded 5",
       repo=REPO, branch="bench/bond-cap-setting",
       benchBaseCommit="84719041b3312cab3e49901dea20d7129bb24761", packageManager="npm",
       baselineExpect={"testsTotal":93,"testsPass":93},
       allowFiles=["packages/shared/src/logic.ts","packages/shared/src/logic.test.ts"],
       srcRevertFiles=["packages/shared/src/logic.ts"],
       testDir="packages/shared", testCmd=["npx","vitest","run","src/logic.test.ts"], installFlags=["--ignore-scripts"]),
  dict(id="asohav-09-seed-virtue-conformance",
       title="ASoHaVCompanionApp: the seeded Basic Moves must carry the Virtue their ruleset headings name",
       repo=REPO, branch="bench/seed-virtue-conformance",
       benchBaseCommit="8686bf41c9ac130bd521f05e056460ca777f43bf", packageManager="npm",
       baselineExpect={"testsTotal":368,"testsPass":368},
       allowFiles=["packages/shared/src/seedLibrary.ts","packages/shared/src/seedLibrary.test.ts"],
       srcRevertFiles=["packages/shared/src/seedLibrary.ts"],
       testDir="packages/shared", testCmd=["npx","vitest","run"], installFlags=["--ignore-scripts"],
       acceptance=dict(ref="upstream-fix", commit="aec6644bfd4f92d787253680b7682ed9b0e4c52a", files=["packages/shared/src/seedLibrary.test.ts"]),
       acceptance_note_file="src-text/asohav-09-seed-virtue-conformance.acceptance-note.txt"),
]

def main():
    only = set(sys.argv[1:])
    out = []
    for s in SPEC:
        e = dict(s)
        e["source"] = read("src-text/%s.source.txt" % s["id"], "PLACEHOLDER source")
        e["prompt"] = read("prompts/%s.txt" % s["id"], "PLACEHOLDER prompt")
        if "acceptance" in e:
            acc = dict(note=read(e.pop("acceptance_note_file"), "PLACEHOLDER acceptance note"))
            acc.update(e["acceptance"])
            e["acceptance"] = acc
        ordered = {k: e[k] for k in KEY_ORDER if k in e}
        extra = set(e) - set(ordered)
        assert not extra, extra
        out.append(ordered)
    # checks
    for e in out:
        blob = json.dumps(e, ensure_ascii=False)
        bad = [c for c in blob if ord(c) > 126 or (ord(c) < 32)]
        flag = "NON-ASCII!" if bad else "ascii-ok"
        print("%-40s prompt=%5d source=%4d  %s" % (e["id"], len(e["prompt"]), len(e["source"]), flag))
    path = os.path.join(G, "entries.a1.json")
    json.dump(out, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    open(path, "a").write("\n")
    print("wrote", path)

main()
