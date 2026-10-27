#!/usr/bin/env python3
"""Hand classification of every commit in the window (author-local date >= 2026-09-13).

Reads commits-numstat.tsv (non-merge rows carry the file split; merge rows are blank) and
all-commits.tsv (for merges). Writes window-classified.tsv and prints counts.

Classes: fix | feature | refactor | docs | chore | test-only | release-bump | merge
`sub` records what kind of fix/feature/etc. it is, so 'fix' is not one undifferentiated bucket.
The overrides below are the result of reading every commit message + diff stat by hand (see
verification.md / progress.md); anything not listed falls to the rule-based default and was
eyeballed in the subject listing.
"""
import csv
import re
import sys
from collections import Counter, defaultdict

OUT = "/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-asohav-new"

# sha7 -> (class, sub, note)
OVERRIDE = {
    # --- 2026-09-13 group (asohav-01/02 came from here) ---
    "d83381a": ("docs", "measurement note", "HANDOFF: measured state of live library"),
    "be055be": ("fix", "backend schema/id (already asohav-02)", "changelog id uuid; bundled with 0.53.1 bump"),
    "fe57b89": ("fix", "backend reporting (already asohav-01)", "library write vs audit log; bundled with 0.53.2 bump + web surfacing"),
    "c1d9c43": ("feature", "web", "0.54.0 ProseField: Adventure Prep prose links glossary terms (bundles a layout bug fix, web-only)"),
    "557e080": ("chore", "tooling", "0.54.1 check-docs.mjs version-claim check"),
    # --- docs-only ---
    "d9ee4ed": ("docs", "meeting notes", ""),
    "e680925": ("docs", "planning", "adopt ruleset revision + work plan"),
    "fd4ee01": ("docs", "handoff", ""),
    "fc6953e": ("docs", "architecture", "slice 3 docs"),
    "0260d39": ("docs", "architecture", "slice 1 docs"),
    "e96fbd1": ("docs", "planning", ""),
    "9134904": ("docs", "planning", ""),
    "42d1186": ("docs", "architecture", "slice 2 docs"),
    "7aef612": ("docs", "architecture", "slice 6 docs"),
    "a855a7a": ("docs", "architecture", "slice 7 docs"),
    "b382b9a": ("docs", "architecture", "slice 8 docs"),
    "25ba77c": ("docs", "planning", "decision backlog"),
    "407899c": ("docs", "handoff", "docs only"),
    "929f76a": ("docs", "handoff", "docs only"),
    "32613c1": ("docs", "architecture", "slice 9 docs (touches one engine.ts header comment)"),
    # --- fixes (with or without tests) ---
    "2db8a09": ("fix", "server logic (Rapport clamp)", "party PUT clamped Rapport to the cap; test flips; +1 web line"),
    "21c9586": ("fix", "server attribution", "Misfortune route By = user id -> Hero name / The GM; +web label fix"),
    "a56bb8e": ("fix", "css", "Misfortune card text colour"),
    "c243cf6": ("fix", "css/ui", "Combat header counter + legible notes (contrast bug)"),
    "364efb0": ("fix", "css/ui", "Party link 44px tap target"),
    "1872054": ("fix", "build", "CSS import path broke web build"),
    "a4ef16c": ("fix", "web logic", "Legendary Misfortune turn offered without Misfortune to spend (no test)"),
    "4437987": ("fix", "server concurrency/normalize", "withBondLock read raw Bond, skipped normalizeBond (no test)"),
    "1ec5d53": ("fix", "css", "undefined CSS custom properties"),
    "22fd4fa": ("fix", "css/ui", "44px hit area"),
    "3a46e48": ("fix", "web logic", "Reminders panel missing from PANEL_IDS so Fold all ignored it (no test)"),
    "3507a55": ("fix", "web copy/log", "Calculate log line omitted the ally offer"),
    "32557b9": ("fix", "web logic", "stale 'Aid a Risk Death' 2-Rapport button (no test)"),
    "139b942": ("fix", "web types (typecheck-only guard)", "0.64.3: web char creation dropped improvementIds/loadTier; runtime test does NOT go red"),
    "3a7589d": ("fix", "web types (typecheck-only guard)", "0.64.3 (parallel PR): same bug; expectTypeOf guard; +server route pin"),
    "aec6644": ("fix", "seed data + new invariant test", "0.64.3: m-strike VirtueId null -> v-guile; new seedLibrary.test.ts"),
    "98d7ce5": ("fix", "ci/config", "0.64.1: rename 15 migration files so apply-migrations.yml runs"),
    "d769699": ("fix", "server cascade (End Combat clears Strain) + web", "slice 6 WP 6F; server part is the fix; web is UI/feature"),
    "c6fa889": ("fix", "server missing-creation (Bonds), 3 src + 2 test", "slice 5 WP 5A: fixes HANDOFF open issue 23 (no Bond row ever created)"),
    # --- chores ---
    "a05a27f": ("chore", "copy edit", "glossary full stop"),
    "0c9306a": ("chore", "comment", "doc comment restored"),
    "cefeec8": ("chore", "format", "stray blank line"),
    "4fffb1c": ("chore", "comment", "doc comment rewrap"),
    "63b74d4": ("chore", "ci + SeedVersion (feature-ish)", "0.64.0 release-reliability automation"),
    "e754e1d": ("chore", "ci", "0.64.2 tag-release workflow"),
    # --- test-only ---
    "1b59f84": ("test-only", "smoke (playwright)", "smoke coverage for Debug view; +1 line src for a selector"),
    # --- refactors / perf ---
    "6447bb0": ("refactor", "web extraction", "HeroRollBuilder/TierReport extracted; 'no change in behaviour'"),
    "11119e6": ("refactor", "web extraction", "EncounterView split; 'DOM byte-identical'"),
    "77cf538": ("refactor", "web extraction", "TrackStepper extracted (+ QuestProgress props contract)"),
    "d104982": ("refactor", "bundle/lazy-load", ""),
    "0d43b08": ("refactor", "bundle/lazy-load", ""),
    "a97f488": ("refactor", "bundle/lazy-load", ""),
    "f35a1c7": ("refactor", "dead-code removal", "delete retired shims + their tests"),
    "18f50b7": ("refactor", "dead-code removal", "retire pre-revision Combat helpers + their tests"),
    "dd84af6": ("refactor", "file split", "GM reference seed gets its own file (contract prep)"),
    "65ba05f": ("feature", "rule removal", "retire Hero's Unstable state (ruleset-driven)"),
}

RELEASE_RE = re.compile(r"^(ship|release) \d+\.\d+\.\d+", re.I)


def main():
    rows = {}
    with open(f"{OUT}/commits-numstat.tsv") as fh:
        for r in csv.DictReader(fh, delimiter="\t"):
            rows[r["sha"]] = r
    out = []
    counts = Counter()
    for sha, r in rows.items():
        if r["nparents"] != "1":
            cls, sub, note = "merge", "", ""
        elif sha in OVERRIDE:
            cls, sub, note = OVERRIDE[sha]
        elif RELEASE_RE.match(r["subject"] if "subject" in r else r["subject"]):
            cls, sub, note = "release-bump", "version bump + CHANGELOG/HANDOFF", ""
        else:
            # everything else in this window is a slice / WP commit of the V0.6 revision migration
            n_src, n_test = int(r["n_src"]), int(r["n_test"])
            sub = "slice contract (red-by-design tests)" if "contract" in r["subject"] else "slice work package"
            cls, note = "feature", ""
            if not n_src and not n_test and int(r["n_docs"]) and not int(r["n_css"]):
                cls, sub = "docs", "slice docs"
        out.append((sha, r["date"], r["author"], r["nparents"], cls, sub, note, r["subject"],
                    r["n_src"], r["n_test"]))
        counts[cls] += 1
    with open(f"{OUT}/window-classified.tsv", "w") as fh:
        fh.write("sha\tdate\tauthor\tnparents\tclass\tsub\tnote\tsubject\tn_src\tn_test\n")
        for row in out:
            fh.write("\t".join(map(str, row)) + "\n")
    print(sum(counts.values()), "commits")
    for k, v in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {k:14s} {v}")
    sub_counts = defaultdict(Counter)
    for row in out:
        sub_counts[row[4]][row[5]] += 1
    for cls in ("fix", "feature", "refactor", "chore", "docs", "test-only", "release-bump"):
        print(f"\n[{cls}]")
        for s, n in sub_counts[cls].most_common():
            print(f"   {n:3d}  {s}")


if __name__ == "__main__":
    main()
