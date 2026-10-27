# progress.md (lfc-bot mining)

Started 2026-09-29. Working copy: mine-lfc/repo (clone --local of the mirror). Mirror untouched.
Scripts: analyze.py (classifier + auto-shortlists). Outputs: commits.tsv, shortlist-auto.tsv, scoped-pairs-auto.tsv.

## Status log
- [x] Step 0: read MINING-BRIEF.md, assign-lfc.md, manifest.json, roadmap 825-933.
- [x] Step 1a: scripted classification (analyze.py -> commits.tsv). Heuristic counts (hand-correct pending):
      ALL 174: merge 71, dep-bump 33, docs 23, feature 18, fix 13, release-bump 5, test-only 3, chore 3, refactor 2, other 3
      >=2026-09-13: 47 (matches assignment) ; >=2026-09-21: 13 (matches assignment)
- [x] Step 1b: read every commit message; found fix-shaped work (see candidate notes below)
- [~] Step 2: shortlist.tsv (auto shortlist = 9 rows strict; +47 scoped src/test pairs from bundled commits)
- [~] Step 3: verification (fresh worktrees at PARENT) -- see verification.md
      V1 e644702 digest-split: VERIFIED (7/7 -> red 6/13 -> green 13/13; full 335 -> 341). reproduced in 2 fresh worktrees.
      V2a 64939c4 scryfall-scoped autocomplete: VERIFIED (12/12 -> red 2/14 -> green 14/14; full 342 -> 344).
      V3 0e9d123 admin perm bit: VERIFIED (4/4 -> red 1/5 -> green 5/5; full 341 -> 342).
      V4 d998d2d digest allowedMentions (scoped): VERIFIED (6/6 -> red 1/7 -> green 7/7; full 125 -> 126; vitest 4.1.11 era).
      N1 64939c4 full (3 src + 6 test files): VERIFIED (38/38 -> red 10/46 in 5 files -> green 46/46; full 342 -> 350).
      HARNESS FINDINGS so far: H1 srcRevertFiles must be exactly 1 (pwsh-verified), H2 new src file can't be reverted -> see notes-fairness.md
- [ ] Step 4: candidates.json
- [ ] Step 5: beyond-bug-fixes nominations
- [ ] Step 6: fairness/determinism notes

## Candidate pool (pre-verification notes)
Real fix commits with src+test (whole history): c743371 (08-27), 075eb02(feature really), aaae44a(bundle), d998d2d(bundle), 30b99a5 (= lfc-02, skip),
  e644702, 0e9d123, 64939c4 (all 2026-09-25, NEW since last pull). 31023a0 + 13ed520 are bash/docker fixes with no tests (unrunnable on harness).
Hidden fixes inside feature commits: 170b395 (duplicateWarning kind), 67bddd4 (edit modal absent field), 04c396b (stopAllJobs leak).
Planned verification order: e644702, 64939c4(scryfall-scoped + full 3-src), 0e9d123, d998d2d(digest-scoped).
