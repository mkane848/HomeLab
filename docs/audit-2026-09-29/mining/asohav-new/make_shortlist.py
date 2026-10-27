#!/usr/bin/env python3
"""Build shortlist.tsv.

Mechanical filter (per the brief): non-merge commit in the window touching 1-3 non-test *source* files
(.ts/.tsx under a src/ dir) plus >= 1 test file. Docs-only, lockfile, config-only, snapshot-only,
pure-CSS and version-bump changes never pass the filter (they have no src+test pair).
On top of that: fix-class commits WITHOUT tests are appended (flagged) so the record is complete.
The `triage` column is my hand decision after reading each diff.
"""
import csv
import re

OUT = "/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-asohav-new"

TRIAGE = {
    # verified candidates
    "2db8a09": ("clamp discards banked state (over-eager server clamp)", "VERIFIED A: scoped to party.ts+party.test.ts; 5/5 -> 1/5 red -> 5/5"),
    "d769699": ("missing cascade side-effect on state transition (End Combat must clear Strain on other records)", "VERIFIED B: scoped to combat.ts+combat.test.ts (2 web files dropped); 18/18 -> 1/20 red -> 20/20"),
    "aec6644": ("seed data vs canonical ruleset (data/spec conformance) + new invariant test", "VERIFIED C: one-token seed fix + NEW test file; 368/368 -> 1/371 red -> 371/371"),
    "21c9586": ("audit attribution: raw user id where display name belongs (+ role branch)", "VERIFIED D: scoped to party.ts+party.test.ts (adventures.ts + web dropped); 20/20 -> 2/20 red -> 20/20. Bug never shipped (fix inside the feature PR)"),
    # already mined
    "fe57b89": ("async ordering / partial-failure reporting", "ALREADY asohav-01 (not re-verified here)"),
    "be055be": ("schema/id-generation mismatch", "ALREADY asohav-02 (not re-verified here)"),
    # nominations / notable
    "3a7589d": ("type-level contract drift (hand-written body type vs shared zod schema); tsc is the only oracle", "NOMINATED (a)+(type oracle): runtime vitest does NOT go red; see nominations"),
    "139b942": ("same bug as 3a7589d, parallel PR", "REJECTED as standalone: runtime test passes on the unfixed source (the fix is typing only); superseded by 3a7589d nomination"),
    "c6fa889": ("missing creation + repair-on-read + unique-violation race (3 src + 2 test)", "NOMINATED (a) alt: multi-file; tests only pin the wiring, repo.ts body untested"),
    "7c5a4de": ("authz: GM-only resource on a member-writable document + role gates (feature)", "NOMINATED (e) authz: 2 src + 2 test files"),
    "04bc651": ("Bond rule change + input whitelist (feature/rule change)", "NOT a fix: ruleset-driven rule change; mixed with validation; rejected"),
    "650554c": ("rule text/delta follows revised ruleset (feature)", "NOT a fix: spec change, tests updated with it"),
    "96a1be1": ("clean-break migration; normalizeLibrary identity trap (no write-back per read)", "REJECTED whole (20 files); the normalizeLibrary/logic.test.ts slice is a possible (e) perf-shaped nomination (UNVERIFIED as scoped)"),
    "63b74d4": ("release-reliability automation + SeedVersion (tooling)", "REJECTED: CI/workflow + feature; test is a 13-line check-docs-like addition"),
    "a8833fe": ("feature: server-side creation Improvements + Load (contract-first, tests in same commit)", "NOT a fix; feature slice candidate (1 src + 1 test, fits the 2-file gate)"),
    "bc36a40": ("feature: Quest/starting-pair rule bodies; tests given by contract 21aeb77", "NOT a fix; feature slice with red-by-design tests in the PARENT"),
    "42356ce": ("feature: Combat loop rule bodies; tests given by contract 52f8b9e", "NOT a fix; feature slice with red-by-design tests in the PARENT"),
    "18f50b7": ("dead-code removal with its tests", "REJECTED: refactor/removal, no behaviour to grade"),
    "f35a1c7": ("dead-code removal with its tests", "REJECTED: refactor/removal"),
    "65ba05f": ("rule removal (retire Unstable)", "REJECTED: ruleset-driven removal"),
    "6fbf39a": ("verbatim GM chapter seed data + parser test", "REJECTED: content transcription, new file + test in one commit"),
    "40d61b9": ("GM reference drawer (new module) - review fixes inside a feature", "REJECTED: fix and feature are the same new file; no parent state"),
    "067f738": ("stat-block editor + admin validation (feature)", "REJECTED: feature, 602 src lines"),
    "e4dc29a": ("Progress the Party etc. (feature)", "REJECTED: feature, 8 src files"),
    "a9e6ada": ("release commit carrying a 4-line test tweak", "REJECTED: release bump"),
    # fix-class but no test in commit
    "4437987": ("concurrency: normalize Bond inside its row lock (withBondLock read raw row)", "REJECTED for verification: no test in the commit; candidate for an authored-test (e) concurrency task"),
    "a4ef16c": ("web: Misfortune spend button offered without Misfortune", "REJECTED: web-only, no test"),
    "3a46e48": ("web: PANEL_IDS omits 'reminders' so Fold all skips it (data-list drift)", "REJECTED: no test in commit (a store test file exists; an authored test could grade it)"),
    "32557b9": ("web: stale Rapport 'Aid a Risk Death' button", "REJECTED: web-only, no test"),
    "3507a55": ("web: log line copy", "REJECTED: web-only, no test"),
    "1872054": ("web build: CSS import path (typecheck cannot see CSS imports)", "REJECTED: no test; only `vite build` catches it"),
    "1ec5d53": ("css: undefined custom properties", "REJECTED: pure CSS"),
    "22fd4fa": ("css: hit area", "REJECTED: pure CSS"),
    "364efb0": ("css/ui: tap target", "REJECTED: web-only 1 line, no test"),
    "a56bb8e": ("css: text colour", "REJECTED: pure CSS"),
    "c243cf6": ("css/ui: header legibility", "REJECTED: css + web, no test"),
    "98d7ce5": ("CI: migration filenames vs supabase db push", "REJECTED: config/ci, 15 renames"),
    "e754e1d": ("CI: tag-release workflow", "REJECTED: config/ci"),
    "8f3d304": ("web: Calculate gave 'Focused Boon' (= Advantage) instead of +1 Forward (hidden in feature)", "REJECTED: web-only, no test"),
}


def toolchain(paths):
    tc = set()
    for p in paths:
        if p.startswith("apps/server"):
            tc.add("server: vitest node, supertest + mocked ../repo.js")
        elif p.startswith("packages/shared"):
            tc.add("shared: vitest pure functions")
        elif p.startswith("apps/web"):
            tc.add("web: vitest node env (pure modules only; no jsdom)")
    return " + ".join(sorted(tc)) or "n/a"


def split_files(cell):
    out = []
    for item in cell.split(";"):
        if not item:
            continue
        m = re.match(r"(.+)\(\+(\d+)/-(\d+)\)$", item)
        out.append((m.group(1), int(m.group(2)), int(m.group(3))))
    return out


def main():
    rows = list(csv.DictReader(open(f"{OUT}/commits-numstat.tsv"), delimiter="\t"))
    classes = {r["sha"]: r for r in csv.DictReader(open(f"{OUT}/window-classified.tsv"), delimiter="\t")}
    out = []
    for r in rows:
        if r["nparents"] != "1":
            continue
        n_src, n_test = int(r["n_src"]), int(r["n_test"])
        cls = classes[r["sha"]]["class"]
        passes_filter = 1 <= n_src <= 3 and n_test >= 1
        fix_no_test = cls == "fix" and n_test == 0 and (n_src >= 1 or int(r["n_css"]) >= 1 or int(r["n_cfg"]) >= 1)
        if not (passes_filter or fix_no_test or r["sha"] in TRIAGE):
            continue
        src = split_files(r["src_files"])
        tst = split_files(r["test_files"])
        bug, triage = TRIAGE.get(r["sha"], ("", ""))
        if not triage:
            triage = f"NOT a fix ({cls}): tests accompany new behaviour" if cls in ("feature", "refactor") else f"{cls}"
        out.append({
            "sha": r["sha"], "parent": r["parent"], "date": r["date"], "subject": r["subject"], "class": cls,
            "n_src": n_src, "src_plus": r["src_add"], "src_minus": r["src_del"],
            "n_test": n_test, "test_plus": r["test_add"], "test_minus": r["test_del"],
            "passes_1to3src_plus_test_filter": "yes" if passes_filter else "no",
            "src_files": ";".join(f"{p}(+{a}/-{d})" for p, a, d in src),
            "test_files": ";".join(f"{p}(+{a}/-{d})" for p, a, d in tst),
            "likely_bug_class": bug,
            "toolchain": toolchain([p for p, _, _ in src + tst]),
            "triage": triage,
        })
    # order: verified first, then nominated, then the rest by date
    def key(o):
        t = o["triage"]
        rank = 0 if t.startswith("VERIFIED") else 1 if t.startswith("NOMINATED") else 2 if t.startswith("ALREADY") else 3
        return (rank, o["date"])
    out.sort(key=key)
    cols = list(out[0].keys())
    with open(f"{OUT}/shortlist.tsv", "w") as fh:
        fh.write("\t".join(cols) + "\n")
        for o in out:
            fh.write("\t".join(str(o[c]).replace("\t", " ") for c in cols) + "\n")
    print(len(out), "rows written to shortlist.tsv")
    print("pass filter:", sum(1 for o in out if o["passes_1to3src_plus_test_filter"] == "yes"))


if __name__ == "__main__":
    main()
