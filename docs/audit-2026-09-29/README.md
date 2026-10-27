# The 2026-09-29 benchmark audit: working material

On 2026-09-29 the owner asked a Claude Code cloud session to get up to speed on the project, check the benchmark's findings and methods for bad assumptions, and look for new task candidates in the three upstream repos the tasks are mined from. The session wrote an independent review, had four subagents mine candidate tasks (29 rows in the end), and then worked through five follow-ups with the owner until 2026-10-03. Its files lived in the session's scratch directory, which is lost when the container is reclaimed, so on 2026-10-27 the owner asked for them to be kept. This folder is that record.

Nothing here is read by a script or a guard, and nothing under `tests/` changed. What the audit changed in the repo is in the merged PRs below. It is not the same document as [adversarial-review-2026-09-29.md](../adversarial-review-2026-09-29.md) (PR [#61], merged the same day); the audit corrected parts of that one later (PRs [#65], [#67] and [#75]).

## Where to start

- **A quick read:** this page, then [review-2026-09-29.md](review-2026-09-29.md), sections 0 to 9.
- **How it went and why:** [history/conversation-log.md](history/conversation-log.md) is what the owner typed and what the assistant said back. [history/compaction-summaries.md](history/compaction-summaries.md) holds four model-written summaries, the shortest account of the whole thing.
- **Re-using the method:** [validation-rig/README.md](validation-rig/README.md), [mining/](mining/) and [briefs/](briefs/).
- **Checking a number:** [analysis/audit-data/](analysis/audit-data/) recomputes the review's figures from `tests/results/` as it stood on the dates the review gives.

## Timeline (UTC)

| When | What | Where |
|---|---|---|
| 2026-09-29 15:48 | The owner asks for a review of findings and methods, and for candidate tasks from the three repos' newer commits | [conversation log](history/conversation-log.md) |
| 15:58 to 15:59 | The first wave of six subagents (data audit, methodology critique, four miners) dies at once on the account's usage limit | [subagent prompts](briefs/subagent-prompts.md) |
| 16:58 to 21:59 | Four mining agents run from 17:01 until the limit stops them at 17:26; their notes stay on disk. The session does the audit itself: recomputes the standings and the output-cap census, reads the harness and the plan docs, re-runs four candidates in fresh worktrees | [mining/](mining/), [review](review-2026-09-29.md), [candidates](candidates-2026-09-29.md), [analysis/audit-data/](analysis/audit-data/) |
| 2026-09-30 11:25 to 11:31 | The owner asks about PRs [#61] to [#64]. The review gets its section 9 and the per-attempt table is made | [review §9](review-2026-09-29.md), [per-attempt table](per-attempt-2026-09-30.md) |
| 11:51 to 12:11 | PR [#65] opens and merges: the fix for tasks with two or more `srcRevertFiles`, corrected claims, the standings table and DP11 | |
| 12:12 | "Let's go through those items one by one": the five follow-ups below | |
| 12:27 to 13:20 | [#66], [#67], [#68] and [#69] merge. (The owner's own [#70], DP12, the audit of the 12 passes, landed before item 4 was reached, so item 4 became the delta.) | |
| 2026-10-03 00:42 | [#75] merges (item 4) | |
| 00:44 | "Add all 15 plus the three": item 5 | |
| 01:09 to 01:26 | Five validation agents run 16 minutes before the limit stops them; the session finishes their work | [validation-rig/](validation-rig/) |
| 01:17 | PR [#76] opens as a draft | |
| by 14:08 | The owner has pulled the session into a Windows terminal, run the checks there and pushed `bf21232` (a PowerShell 5.1 fix) | |
| 14:08 and 14:58 | The owner marks [#76] ready at 14:08; it merges at 14:58 | |
| 2026-10-03 | The owner's first runs of the new tasks find `asohav-05` and `asohav-06` unmeasurable and retire them (see below) | [roadmap](../roadmap.md) |
| 2026-10-26 and 27 | The owner asks whether the session is safe to close, then to record the work: this folder | |

## The five follow-ups

After PR [#65] the assistant listed what was still open, and the owner took the items in order.

| # | Follow-up | PR | Merged |
|---|---|---|---|
| 1 | Tell an output-cap hit from liar mode in the writes gate | [#66] | 2026-09-30 |
| 2 | Put the opencode version in the "same config" key, and run replicates rep-outer | [#67] | 2026-09-30 |
| 3 | Make the `bench/*` tasks reproducible: pin every base by SHA, publish `kane-01`'s, pin `lfc-03`'s acceptance commit | [#68], [#69] | 2026-09-30 |
| 4 | Replay audit of the 12 new passes. The owner's [#70] (DP12) landed first, so this PR added a second replay; it also pins each task's test environment | [#75] | 2026-10-03 |
| 5 | Add the mined candidates to the suite (18 tasks, so 27), and grade `failsOnOld` without the repository-global `git stash` | [#76] | 2026-10-03 |

## What the audit found, and what became of it

Section numbers are those of [review-2026-09-29.md](review-2026-09-29.md).

| Finding | What became of it |
|---|---|
| The step-6 standings reproduce from `tests/results/`. The top tier was real; the order inside it could not be told apart at one attempt per cell (§0, §1). After PRs [#61] to [#64] the same-config data moved it: `qwen3.6` 14 of 15 attempts against `qwen3.5` 13 of 21 (§9) | Recorded as "Executor standings after the N>1 protocol" in the [roadmap](../roadmap.md) and as DP11 in [implementation-tasks.md](../implementation-tasks.md) (PR [#65]). Re-seating stayed the owner's decision |
| Output-cap hits were filed as "liar mode": 8 of the 31 exit-0 zero-write rows since 2026-09-22 (§2) | The writes gate tells them apart and run JSONs record `outputCapHit`; guard `tests/test-cap-hit.ps1` (PR [#66]) |
| `failsOnOld` needs the model's own test, which the target executor is not meant to write, and only `lfc-03` had an owner acceptance block (§3) | 15 of the 18 new tasks carry an informational `acceptance` block (PR [#76]). The other eight original tasks still have none |
| Blind spots in the `failsOnOld`, suite and scope gates (§4) | Not acted on in these PRs. The owner's harness audit of 2026-10-26 (see the CHANGELOG) changed the suite and `failsOnOld` gates in related ways |
| Task bases were not reproducible: seven of eight `bench/*` branches existed only on the owner's disk, and `kane-01` pinned a mutable branch (§4, §7.8) | Every task pins a full SHA and the harness runs the pin (PR [#68]); `kane-01`'s base is published and `lfc-03`'s acceptance commit pinned (PR [#69]) |
| "Private, unpublished bugs, structurally immune" is wrong: the three source repos are public (§4) | Docs corrected (PR [#65]) |
| Docs and instructions that no longer matched the data: the main seat, "only qwen3 calls tools", context sizes, stale lists (§5) | Corrected in PR [#65]. Those pages have since been rewritten and moved by the owner (`AGENTS.md` became `docs/reference/` on 2026-10-26) |
| Harness problems found while mining (§7) | (1) Two or more `srcRevertFiles` could not be graded: fixed in PR [#65], then the revert was rebuilt without `git stash` in PR [#76]. (5) An ambient `MANAPOOL_API_KEY`: per-task `testEnv` pins (PR [#75]). (8) The mutable `kane-01` pin: PRs [#68] and [#69]. Not acted on in these PRs: (2) a fix that creates a new source file cannot be graded (the revert now says so instead of keeping the file), (3) no task kind for given-tests work, (4) the typecheck step runs `pnpm exec tsc` in npm repos, (6) the lfc-bot lockfile under npm 10, (7) ASoHaV server tests read `packages/shared` through a build made once |
| 29 candidate tasks (§8, [candidates](candidates-2026-09-29.md)) | 18 added (PR [#76]). The other 11, and why, are in the roadmap's "Not added" table. The two KaneEnabler tasks whose tests the mining agent wrote itself (`kane-05`, `kane-06`) are in [mining/kane/artifacts/](mining/kane/artifacts/) |
| Recommended experiments: a plain-language arm, a repeatability probe, a re-seat decision (§6) | The owner's, outside these PRs. See [main-seat-trial.md](../main-seat-trial.md) |

## What happened to the new tasks

The 18 tasks went into the suite on 2026-10-03 with no graded rows. By 2026-10-26 `tests/results/tasks-summary.tsv` held 73 rows on them (`qwen3.6`, `qwen3.5` and `qwen3:8b`). On their first run, `qwen3.6` could not see the task in two of them. At the pins of `asohav-05` and `asohav-06` the repository's `CLAUDE.md` was about 280 KB, OpenCode loads that file into every request, and Ollama cut the prompt to 32,770 tokens, which read as liar mode. The owner retired both tasks (roadmap, "`asohav-05` and `asohav-06` retired"). Their ids, pins and rows stay.

The validation rig could not have caught this. It is the clearest gap in the method, and the next section says what else the rig could not see.

## What the validation rig could and could not catch

The rig answers one question: does the real harness grade a known fix and a known non-fix the way the manifest entry says it should, in a fresh worktree, whatever the environment? It said yes for all 18 entries. It says nothing about a model.

- **The prompt a model receives.** OpenCode adds the repo's own instruction file to every request and the stand-in never builds a request. The validation brief's hazard review ([briefs/validation-brief.md](briefs/validation-brief.md), step 7) did not list it. A pre-flight that measures `AGENTS.md` or `CLAUDE.md` at each pin would have caught `asohav-05` and `asohav-06`.
- **Windows.** The rig ran PowerShell 7 on Linux. The owner's first guard run on Windows PowerShell 5.1 found `Get-PublishState` failing under `$ErrorActionPreference = "Stop"` (fixed in `bf21232`, PR [#76]). The line-ending hazard of `asohav-09` was found by reading; the owner's dry run on Windows passed its 368-test baseline on a CRLF checkout.
- **Model behaviour.** The 18 prompts were reviewed against the upstream diffs for leaks and for the names the acceptance tests depend on. A blind-solver check was prepared (`validation-rig/tools/blind_setup.sh`, `blind_collect.sh`, the stand-in's `blind` mode) and never run.
- **What the upstream tests leave unpinned.** Mutating each reference fix and running the upstream tests showed which parts they do not cover; the roadmap lists them under "What the gates cannot check", and the raw results are in [validation-rig/mutation-checks/](validation-rig/mutation-checks/).

## What is here

| Folder | Holds |
|---|---|
| [review-2026-09-29.md](review-2026-09-29.md), [per-attempt-2026-09-30.md](per-attempt-2026-09-30.md), [candidates-2026-09-29.md](candidates-2026-09-29.md) | The audit's three written records, as written |
| [history/](history/) | The conversation log (owner messages and the assistant's replies) and the four compaction summaries |
| [briefs/](briefs/) | The briefs and assignments the subagents were given, the validation brief, and all 23 subagent prompts with how each run ended |
| [mining/](mining/) | Each mining agent's progress notes, shortlist, verification log and scripts, and the tests and reference fixes written for `kane-05` and `kane-06` |
| [analysis/audit-data/](analysis/audit-data/) | The scripts behind the review's figures (read-only over `tests/results/`) |
| [analysis/replay-12/](analysis/replay-12/) | The replay of the 12 passes (item 4): scripts, outputs, the replayed diffs |
| [analysis/verify/](analysis/verify/) | Scripts and outputs from checking the follow-ups: mutants of the guards, the pin checks, the `git ls-remote` listings of the three repos, the nested-argument reproduction |
| [analysis/harness-mutants/](analysis/harness-mutants/) | The mutants used to show the `testEnv` guard and the stash-free revert guard fail when the code is wrong, as diffs against the harness version each was cut from |
| [validation-rig/](validation-rig/) | The rig, its reference patches, the agents' drafts and notes, both batteries of runs, the mutation checks and the evidence of the shared-stash hazard |
| [MANIFEST.tsv](MANIFEST.tsv) | Every archived file: where it came from and its SHA-256 |

## Left out

- The clones and worktrees of the three repos (about 15 GB in all), `node_modules` and build caches. The SHAs in `tests/tasks/manifest.json` and the scripts here regenerate them.
- The bulk tables the mining scripts write (commit lists, per-commit file counts, classified JSON, commit bodies). Run the scripts in `mining/`.
- Copies of upstream source and docs the agents kept for reading (`CLAUDE.md` files, `*.bak`, the 2 MB ruleset). Regenerate them from the SHAs.
- The raw result JSONs of the stand-in runs. `validation-rig/battery-*/runs.tsv` has one row per run with the gates and the acceptance detail, and `logs.txt` has every log.
- The `testEnv` manifest mutants (M12 to M16). `analysis/harness-mutants/testenv/mutants.py` produces them.
- The session transcript. `history/` keeps the visible text only: owner messages, the assistant's replies to the owner, the subagent prompts and the four compaction summaries. Tool calls, tool output and reasoning are not kept. The repo keeps session transcripts untracked by convention (`.gitignore`, `session-*.md`).

## Provenance and caveats

- Files are copied byte for byte from the session's scratch directory. `MANIFEST.tsv` gives each file's origin and the SHA-256 of what is stored; generated files say `generated:`. The four READMEs and `MANIFEST.tsv` are the only files written for this folder. One file had a model identifier in quoted commit metadata replaced with `[model id omitted]`, and the history files do the same wherever one appeared.
- The scripts are kept as they ran in the cloud container: absolute paths (`/home/user/HomeLab`, the scratch directory), PowerShell 7 on Linux. They record the method; they are not maintained tools. Live tooling belongs in `tests/`.
- The harness has moved on. The rig copied `tests/test-tasks.ps1` as it stood on 2026-10-03. Since then it has gained sealed checkouts, retired tasks and other acceptance modes, among other changes (see the CHANGELOG). Rebuild the rig from the current harness before using it, and expect the stand-in's event stream to need changes if the transcript reader changed.
- The written records are kept as written. Their figures are as of the dates they state (the review used `tests/results/` at `origin/main` on 2026-09-29, and `20c3417` for §9), and some have been superseded; the table above says which.
- The history files are model-written or model-adjusted text. The compaction summaries are summaries, not transcripts, and may contain slips.
- The session's own checks ran on Linux. The Windows runs are the owner's (PR [#76]).

[#61]: https://github.com/mkane848/HomeLab/pull/61
[#62]: https://github.com/mkane848/HomeLab/pull/62
[#63]: https://github.com/mkane848/HomeLab/pull/63
[#64]: https://github.com/mkane848/HomeLab/pull/64
[#65]: https://github.com/mkane848/HomeLab/pull/65
[#66]: https://github.com/mkane848/HomeLab/pull/66
[#67]: https://github.com/mkane848/HomeLab/pull/67
[#68]: https://github.com/mkane848/HomeLab/pull/68
[#69]: https://github.com/mkane848/HomeLab/pull/69
[#70]: https://github.com/mkane848/HomeLab/pull/70
[#75]: https://github.com/mkane848/HomeLab/pull/75
[#76]: https://github.com/mkane848/HomeLab/pull/76
