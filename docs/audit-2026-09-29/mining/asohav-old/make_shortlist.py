#!/usr/bin/env python3
"""Build shortlist.tsv.

Pool 1 ("raw"): scripted filter over the window: non-merge commits touching 1-3 non-test SOURCE files (apps/*/src, packages/*/src, non-css/docs/lock/config)
                AND at least one test file. Nothing else is filtered by judgement; the class column is my read of the diff.
Pool 2 ("scoped"): fixes hidden inside bundle commits (found via CHANGELOG 'Fixed' sections + added-test-name scan), with the file scope I actually used or would use.
Pool 3 ("nomination"): shapes the current suite cannot express (see nominations in the report).
"""
import json, os, subprocess

S = os.path.dirname(os.path.abspath(__file__))
data = json.load(open(os.path.join(S, "classified.json")))

def short(p):
    return p.split("/")[-1]

rows = []
for r in data:
    if r["kind"] != "commit":
        continue
    files = r["files"]
    src = [f for f in files if f[3] == "src"]
    tst = [f for f in files if f[3] == "test"]
    if not tst or not (1 <= len(src) <= 3):
        continue
    sha = r["sha"]
    rows.append(dict(
        pool="raw", sha=sha[:7], parent=r["parent"][:7], date=r["date"][:10], subject=r["subj"][:110],
        src=";".join(f[0] for f in src), test=";".join(f[0] for f in tst),
        src_pm="+%d/-%d" % (sum(f[1] for f in src), sum(f[2] for f in src)),
        test_pm="+%d/-%d" % (sum(f[1] for f in tst), sum(f[2] for f in tst)),
        cls=r["cls"], bug_class="", toolchain="", status="", notes="",
    ))

# hand-classification of the raw pool (my read of each diff)
RAW = {
    "7dffdbc": ("feature (new engine)", "shared/vitest node", "REJECT", "new module + tests added together; nothing pre-existing to fix"),
    "2729b58": ("enum 3-way branching (Neutral treated as Negative) + spec change (Virtue arrays)", "shared/vitest node", "VERIFIED as B (scoped to engine.ts)", "bundle of a rules-data change and a bug; only the engine.ts sites are scoped in"),
    "52d9def": ("feature (chargen chooses from five arrays)", "shared+server/vitest", "REJECT", "feature; test change is +1/-1"),
    "87336e6": ("feature (new sortStatuses())", "shared/vitest node", "NOMINATION candidate (c-lite)", "new exported function; pure-function feature slice"),
    "3003542": ("early return skips markup parsing (raw [display][id] brackets leak) + depth-cap constant", "shared/vitest node", "VERIFIED as A (scoped to glossary.ts)", "roadmap said DROPPED (bundled with React component + CSS + See-also feature); the test change is shared-only so it scopes cleanly"),
    "9e64bc3": ("feature (Gambits)", "shared/vitest node", "REJECT", "feature"),
    "11aa2cd": ("feature (Opportunity Attack/Interpose)", "shared/vitest node", "REJECT", "feature"),
    "e0c7032": ("feature (write-in answers, adminLogic validation)", "server/vitest", "REJECT", "feature"),
}
for r in rows:
    if r["sha"] in RAW:
        r["bug_class"], r["toolchain"], r["status"], r["notes"] = RAW[r["sha"]]
    else:
        r["bug_class"], r["toolchain"], r["status"], r["notes"] = ("?", "?", "REJECT", "raw-filter hit; not a bug fix on inspection of subject/test names")

# curated pool: scoped-out fixes. parent = first parent of the fix commit (full sha resolved below)
def full(sha):
    return subprocess.check_output(["git", "-C", os.path.join(S, "repo"), "rev-parse", sha], text=True).strip()

CUR = [
    # sha, date, subject, src, test, src_pm, test_pm, class, toolchain, status, notes
    ("3e0b074", "2026-09-12", "Ship 0.51.0: Content Admin, phases 1 and 2 (scoped: write-route input validation)",
     "apps/server/src/routes/library.ts;apps/server/src/adminLogic.ts", "apps/server/src/routes/library.test.ts", "+~65/-~8", "+85/-0 (2 describe blocks)",
     "missing input validation / mass assignment (settings patch null->disabled feature; required/default ignored; client Id overrides generated)", "server/vitest+supertest+express, repo mocked; needs @asohav/shared built",
     "VERIFIED as D", "14/14 -> 8/24 -> 24/24; dropped restore route, delete-reference guard, rowsOf refactor, all web changes"),
    ("3615d3d", "2026-09-11", "Ship 0.50.0 (scoped: Bond cap reads GameSettings.BondTrackLength, not literal 5)",
     "packages/shared/src/logic.ts", "packages/shared/src/logic.test.ts", "+~30/-~14", "+~40/-0 (1 describe block)",
     "hardcoded constant vs admin-editable setting across 3 coordinated pure functions", "shared/vitest node",
     "VERIFIED as C", "93/93 -> 3/97 -> 97/97; fix-commit tests miss 2 of 6 sites (mutants M5/M6 survive); 2 extra acceptance tests drafted+verified"),
    ("3615d3d", "2026-09-11", "Ship 0.50.0 (scoped: four mutating campaign routes ignore the archive freeze)",
     "apps/server/src/routes/campaign.ts (phase, ready, invite revoke)", "apps/server/src/routes/campaign.test.ts", "+3/-0", "+49/-0 (4 tests)",
     "missing state guard on 3 sibling handlers (sweep-style)", "server/vitest+supertest",
     "SHORTLISTED - UNVERIFIED (cap of 4 verified reached)", "parent 8471904; fix-commit tests import new errorMiddleware.ts and rely on CampaignArchivedError.status=409 in shared: a scoped test would need the sibling try/catch->409 pattern; class overlaps lfc-01/03"),
    ("3615d3d", "2026-09-11", "Ship 0.50.0 (scoped: POST /combat/:id/end ignores the archive freeze)",
     "apps/server/src/routes/combat.ts", "apps/server/src/routes/combat.test.ts", "+4/-0", "+16/-0 (1 test)",
     "missing state guard (1 handler)", "server/vitest+supertest", "REJECT", "same class as lfc-01; 1 test; needs errorMiddleware.ts; subsumed by the campaign.ts entry"),
    ("3615d3d", "2026-09-11", "Ship 0.50.0 (scoped: content library optimistic locking)",
     "apps/server/src/repo.ts;apps/server/src/routes/library.ts", "apps/server/src/routes/library.test.ts (NEW file at fix commit)", "+~60/-~20", "+156/-0",
     "concurrency: lost update on whole-blob read-modify-write", "server/vitest+supertest, repo mocked",
     "SHORTLISTED - UNVERIFIED (nomination (e) alt)", "test file does not exist at the parent (baseline would be full-suite like asohav-02); changes repo contract (getLibraryWithVersion/saveLibrary(lib, version)); multi-file"),
    ("3615d3d", "2026-09-11", "Ship 0.50.0 (scoped: read-time normalizeBond/Encounter/Adventure)",
     "packages/shared/src/logic.ts;apps/server/src/repo.ts", "packages/shared/src/logic.test.ts", "+~70/-0", "+~65/-0",
     "missing read-time backfill of legacy JSONB rows", "shared/vitest node", "REJECT", "fix = three NEW exported functions; red would be TypeError (missing helper), not behaviour"),
    ("7070bf7", "2026-08-10", "Audit fixes (scoped: Bond Kin-lock - isBondLocked/applySpendKin guard + ForgeBond route guard)",
     "packages/shared/src/logic.ts;apps/server/src/routes/bond.ts", "apps/server/src/routes/bond.test.ts (+ shared logic.test.ts)", "+~30/-0", "+33/-0 (2 route tests)",
     "unenforced rule (locked Bond could be spent/forged) across 2 packages", "server/vitest+supertest against BUILT shared dist",
     "NOMINATION (a) - see verification.md", "cross-package: tests go through @asohav/shared dist; harness `setup` runs once"),
    ("7070bf7", "2026-08-10", "Audit fixes (scoped: normalizeLibrary self-heal on read)",
     "packages/shared/src/logic.ts;apps/server/src/repo.ts", "packages/shared/src/logic.test.ts", "+~50/-~3", "+~78/-0",
     "missing read-time backfill", "shared/vitest node", "REJECT", "new exported function => red is a missing-helper TypeError"),
    ("7070bf7", "2026-08-10", "Audit fixes (scoped: Dishonored -> Vulnerable 4 in Combat)",
     "packages/shared/src/combat.ts", "packages/shared/src/combat.test.ts", "+~22/-1", "+~50/-1",
     "unimplemented promised mechanic (placeholder)", "shared/vitest node", "REJECT", "new exported function applyDishonoredVulnerable; feature-shaped, and the later V0.5/V0.6 slices rewrote it"),
    ("b515c42", "2026-08-10", "Fix crash loading a pre-0.13.0 character sheet (0.16.1)",
     "packages/shared/src/logic.ts;apps/server/src/repo.ts;apps/web StatusesPanel.tsx;EncounterView.tsx", "packages/shared/src/logic.test.ts", "+32/-11", "+43/-1",
     "legacy row missing fields -> unguarded .length crash", "shared/vitest node", "REJECT", "fix = new exported normalizeSheet(); red is a missing-helper TypeError; the crash itself is in React code with no test"),
    ("105b2ff", "2026-08-13", "fix(engine): split roll-breakdown Total from Status, drop Advantage toggle",
     "packages/shared/src/engine.ts (+3 web files)", "packages/shared/src/engine.test.ts", "+42/-~30", "+9/-5",
     "product/UX decision (owner feedback), adds new RollBreakdown.StatusSources field", "shared/vitest node", "REJECT", "spec change with API-shape change; prompt would have to dictate the new field; not a defect"),
    ("4c068e2", "2026-08-16", "Server round-trip fixes: bootstrap N+1, user/campaign scoping, encounter filter",
     "apps/server/src/repo.ts;routes/admin.ts;routes/campaign.ts;routes/invites.ts", "admin.test.ts;campaign.test.ts;invites.test.ts", "+97/-36", "+79/-10",
     "perf N+1 + over-fetch (every registered account shipped to every campaign client)", "server/vitest+supertest, repo mocked",
     "NOMINATION (e) alt / (a) alt", "4 src + 3 test files; tests assert on NEW repo function names (listUsersByIds, listCampaignsByIds, listMembershipsForCampaigns) so the prompt must dictate them"),
    ("256e91f", "2026-08-14", "Fix two bugs found in an adversarial review (GlossaryAutoLink cache keyed only on glossary ref)",
     "apps/web/src/lib/useGlossaryMatcher.ts", "(none in this commit; apps/web/src/lib/useGlossaryMatcher.test.ts was added 2 days later by b44f110)", "+25/-12", "0",
     "stale cache: WeakMap keyed on one dependency", "web/vitest node", "REJECT (for now)", "no test at the fix commit and no real parent has both bug + test; would need a synthetic 'revert the fix' base"),
    ("a593702", "2026-08-13", "fix(web): rework commit() mutations with rollback, Toast, and settle-time invalidate",
     "apps/web/src/lib/mutations.ts;AppShell.tsx;toastStore.ts", "(none)", "+126/-45", "0",
     "optimistic-update with no rollback (React Query hook)", "web", "REJECT", "no test; would need jsdom + @testing-library + QueryClient harness"),
    ("89db373", "2026-08-08", "Fix production crash loop behind hanging invite-accept requests (0.12.1)",
     "13 server/web src files", "(none)", "+147/-80", "0", "unhandled rejection crash loop", "server", "REJECT", "no test change in the fix"),
    ("b9ee794", "2026-08-03", "Fix seed FK ordering crash on the seeded campaign", "apps/server seed files (2)", "(none)", "+13/-6", "0",
     "FK ordering in seed", "server (needs a DB)", "REJECT", "no test; needs a live Postgres"),
]
for sha, date, subj, src, tst, spm, tpm, cls, tool, status, notes in CUR:
    rows.append(dict(pool="scoped", sha=sha, parent=full(sha + "^")[:7], date=date, subject=subj, src=src, test=tst, src_pm=spm, test_pm=tpm,
                     cls="(bundle)", bug_class=cls, toolchain=tool, status=status, notes=notes))

cols = ["pool", "sha", "parent", "date", "subject", "src_files", "test_files", "src_pm", "test_pm", "commit_class", "bug_class", "toolchain", "status", "notes"]
with open(os.path.join(S, "shortlist.tsv"), "w") as f:
    f.write("\t".join(cols) + "\n")
    for r in rows:
        f.write("\t".join([r["pool"], r["sha"], r["parent"], r["date"], r["subject"], r["src"], r["test"], r["src_pm"], r["test_pm"], r["cls"], r["bug_class"], r["toolchain"], r["status"], r["notes"]]).replace("\n", " ") + "\n")
print(len(rows), "rows;", sum(1 for r in rows if r["pool"] == "raw"), "raw,", sum(1 for r in rows if r["pool"] == "scoped"), "scoped")
