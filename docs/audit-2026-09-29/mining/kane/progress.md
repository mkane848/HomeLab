# KaneEnabler mining progress (started 2026-09-29)

- [x] read MINING-BRIEF.md, assign-kane.md, manifest.json, roadmap 825-933, implementation-tasks 127-170
- [x] working clone: mine-kane/repo (git clone --local of upstream mirror; mirror untouched)
- [~] step 1 (raw table saved: commits-cat.json; classification pending): list + classify all 309 commits (197 non-merge, 112 merge, 84 first-parent)
- [ ] step 2: shortlist.tsv
- [ ] step 3: verification (fresh worktree per candidate)
- [ ] step 4: candidates.json
- [ ] step 5: beyond-bug-fixes nominations
- [ ] step 6: harness fairness notes
- [ ] EXTRA: fetch review-gate/deck-validity, check open defects (deckValidity.ts named commanders / singleton paper-rule / banned-notFound dedupe)

## EXTRA (2026-09-29): review-gate/deck-validity fetch
- fetched with `git fetch --depth=300 https://github.com/mkane848/kaneenabler review-gate/deck-validity` (anonymous OK)
- branch tip = 92a8ed0df10262cc878d4d214d0a312d542375ec  == kane-01 base 92a8ed0 (EQUAL; tip has not moved as of fetch)

## Status 2026-09-29 (after branch defects)
- [x] branch tip fetched (== 92a8ed0); K05 singleton + K06 commander-legality/dedupe VERIFIED (wt/dv-k05, wt/dv-k06; artifacts/kane-05.*, kane-06.*)
- [ ] mined candidates to verify next: e952198(signals.ts scoped), 731e985, 271636f pieces (UndoToast, ComboPreferenceRow, scryfallFields, useAuth, errorHandler), e0ef290, 4029a94
- classification of 197 non-merge commits: pending (raw file/numstat data in commits-cat.json, pairs.txt)
