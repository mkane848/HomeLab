# Mining notes

Four subagents mined candidate benchmark tasks from the three upstream repos on 2026-09-29. They followed [the mining brief](../briefs/mining-brief.md) and a per-repo assignment ([briefs/](../briefs/)), each in its own scratch directory. This is what they left. The usage limit stopped them at 17:26 UTC before they wrote final reports, so the figures come from their own verification logs; the session re-ran four candidates independently (`../analysis/verify/spot.sh`) and all matched. The session consolidated the shortlists into [candidates-2026-09-29.md](../candidates-2026-09-29.md) (29 rows) and renumbered them there, so a candidate's id in an agent's file may differ from its id in that table.

| Folder | Repo | Window |
|---|---|---|
| `kane/` | KaneEnabler | the whole history (309 commits in the mirror, 2026-07-24 to 2026-09-25), plus the open defects on the unmerged `review-gate/deck-validity` branch |
| `lfc/` | lfc-bot | the whole history (174 commits, 2026-08-25 to 2026-09-25), with the commits since 2026-09-13 classified as new |
| `asohav-old/` | ASoHaVCompanionApp | commits dated before 2026-09-13 (377 by author-local date) |
| `asohav-new/` | ASoHaVCompanionApp | commits dated 2026-09-13 or later (174) |

## What each folder holds

- `progress.md`: the agent's status log, appended as it went.
- `verification.md`: one section per candidate that was verified in a fresh worktree at the parent commit: the install, the baseline count, the fix commit's tests alone against the unfixed source, the fully fixed run, with the runner's summary lines pasted in.
- `shortlist*.tsv`, `scoped-pairs-auto.tsv`: the commits that looked like fixes, with their source and test files.
- The classification and shortlisting scripts (`classify.py`, `classes.py`, `analyze.py`, `make_shortlist.py`, `extract.py`, `pairs.py`) and the verification scripts (`vsetup.sh`, `vrun.sh`, `verify.sh`, `verify_shared_wp.sh`, `showfix.sh`).
- `lfc/notes-fairness.md`: what would make a task unfair, non-deterministic or unrunnable on the Windows harness, observed or read. Its first item is the nested-array bug that stopped any task with two source files from being graded (fixed in PR [#65]).
- `kane/artifacts/`: the tests and the reference fix the agent wrote for `kane-05` (the singleton copy limit) and `kane-06` (commander legality and dedupe). These two are open defects on the unmerged branch with no upstream fix commit, so the tests are the agent's, not the project's. They were not added to the suite.

The bulk tables the scripts wrote (every commit with its file counts, classified JSON, commit bodies) are not kept; the scripts regenerate them from a clone.

[#65]: https://github.com/mkane848/HomeLab/pull/65
