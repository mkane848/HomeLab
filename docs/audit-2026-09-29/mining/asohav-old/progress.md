# progress.md - asohav OLD window (author date < 2026-09-13)

Started 2026-09-29. Working copy: ./repo (git clone --local of the mirror). Verification worktrees under ./wt/ (fresh per candidate).

## Status log (append-only)
- [x] read MINING-BRIEF.md, assign-asohav-old.md, manifest.json, roadmap 825-933
- [x] window: 377 commits by author-local date < 2026-09-13 (140 merge commits: 129 "Merge pull request", 11 sync merges); last commit in window = c6bc1fd (merge of PR #135, asohav-01's parent).
  - boundary note: d83381a and be055be are authored 2026-09-13 01:xx +0000 (= 21:xx -0400 on 09-12) and sit INSIDE PR #135 that merged 22:12 -0400 on 09-12; by raw date they belong to the sibling's window; be055be = asohav-02 (skip); d83381a = docs. Nothing lost.
  - first-parent commits in window: 134. Non-merge: 237.
- [x] numstat script: analyze.py -> numstat.json, commit-table.tsv; classify.py -> classified.tsv (rule-based, overrides pending)
- [ ] hand-review classification, finalize counts
- [ ] shortlist.tsv
- [ ] verification.md (per candidate)
- [ ] candidates.json
- [ ] beyond-bug-fixes nominations
- [ ] Windows/harness notes

## Leads so far (from subjects + CHANGELOG "Fixed" sections)
- 2729b58 fix(shared): Virtue-array rules + Neutral Status treated as Negative (2 src + 2 test)
- 105b2ff fix(engine): roll-breakdown Total vs Status (CHANGELOG 0.21.0 "real Roll 2d6 + Heart: +5 bug")
- b515c42 crash loading pre-0.13.0 sheet (read-time normalize)
- 7070bf7 Audit fixes bundle (normalizeLibrary, Bond Kin-lock, Martyr, Dishonored Vulnerable)
- 4c068e2 server round-trip fixes (N+1, user/campaign scoping, encounter filter)
- 3003542 glossary depth cap + See also chips (roadmap says DROPPED; re-examine, React nomination?)
- 3615d3d 0.50.0 bundle: archive-freeze on 4 routes, read-time normalizes, Bond cap config, optimistic locking
- 3e0b074 0.51.0 bundle: settings patch validation, required/default enforcement, Id override order (library.ts)

## Update 2026-09-29 (mid-run)
- [x] 4 tasks VERIFIED in fresh worktrees (see verification.md): 
  - A glossary depth-cap + tag flattening (3003542 scoped to shared/glossary.ts): baseline 20/20 -> red 2/21 -> green 21/21   [re-examined the roadmap-DROPPED candidate: scopable]
  - B Neutral Status polarity (2729b58 scoped to shared/engine.ts): 22/22 -> 2/24 -> 24/24
  - C Bond cap hardcoded 5 (3615d3d scoped to shared/logic.ts): 93/93 -> 3/97 -> 97/97 (+2 extra acceptance tests close a coverage gap: red 5/99 -> 99/99)
  - D Content Admin write-route validation (3e0b074 scoped to server library.ts + adminLogic.ts): 14/14 -> 8/24 -> 24/24   [needs `setup`: build @asohav/shared]
- cap of 4 verified candidates reached; E (archive-freeze on phase/ready/revoke, 3615d3d, parent 8471904) is on the shortlist UNVERIFIED (not run because of the cap).
- Discovery: repo has NO jsdom / @testing-library anywhere in its history; web tests are node-env store/lib tests + Playwright smoke scripts.
- Discovery: server tests resolve @asohav/shared through package exports -> dist, so any task whose fix touches packages/shared but is graded by a server test needs the
  shared dist rebuilt after the model's edit (the harness only runs `setup` once).
- TODO: shortlist.tsv, nominations (a) Bond Kin-lock cross-package 7070bf7 (parent 75b8855), (b) React GlossaryText depth bug (parent 5c89193, needs jsdom), (c) feature slice
  (restore-from-changelog route in 3e0b074, parent 79b369d), candidates.json, classification counts, harness/Windows notes, final report.
