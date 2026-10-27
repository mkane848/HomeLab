# progress.md - ASoHaV NEW window (>= 2026-09-13)

Last updated: 2026-09-29 (in progress)

## State
- [x] Read MINING-BRIEF.md + assign-asohav-new.md + manifest.json + roadmap mining protocol
- [x] Own working clone: mine-asohav-new/repo (git clone --local of the mirror; mirror untouched)
- [x] Window enumerated: 174 commits dated >= 2026-09-13 (author-date == committer-date count). 8 on 09-13, then a gap, then 166 on 09-22..09-27.
      131 non-merge, 43 merge. (Assignment said ~171; exact number is 174.)
- [x] numstat split script: classify.py -> commits-numstat.tsv (src/test/css/docs/cfg/sql/smoke counts per commit)
- [ ] hand classification of every commit (class counts)
- [ ] shortlist.tsv
- [ ] verification of best candidates in FRESH worktrees
- [ ] candidates.json
- [ ] beyond-bug-fixes nominations
- [ ] Windows-harness notes

## Early observations
- The window is dominated by the "V0.6 revision" migration: ten "slice" PRs, each a chain of "contract" + "WP xx" commits. Few labelled fixes.
- Known already-mined: fe57b89 (asohav-01) and be055be (asohav-02).
- apps/web has NO jsdom / testing-library (vitest env is node) - React component tests are not expressible here; web tests can only cover pure modules.
