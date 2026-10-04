# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Light-seat overnight batch (2026-10-03/04): `qwen3:8b`, the main seat of
  three of the four live profiles, and `qwen3.5:9b` on every active task each
  had no graded row for. `qwen3:8b` passed 0 of 17 attempts (12 graded, 5
  timeouts; 1 of 47 graded runs on the desktop overall), changing only tests,
  leaving no net change, or repeating writes up to 108 times. `qwen3.5:9b`
  passed 9 of 16, the same tasks `qwen3.6` passes and mostly in 1–2 minutes,
  with 2 crashes from its chat template's `No user query found in messages`
  error at 50–54k tokens of context, a known property of the seat. No prompt
  was truncated. The roadmap's "Task set expansion II" records it and the
  re-seat question it raises (owner decision); `tests/results/README.md`
  notes that timeout transcripts have been kept since 2026-09-26.

- Second `qwen3.6` run of the 16 active new tasks (2026-10-03 evening, same
  versions and config as the first, 1800 s cap): 11 of 15 graded runs pass;
  `kane-08` hit the cap with no edit (no row). Across both runs 10 tasks pass
  twice, `asohav-07` and `asohav-09` once, and `kane-07`, `kane-08`, `kane-14`
  and `lfc-07` never. Recorded in the roadmap's "Task set expansion II".
- `failsOnOld` is now `SKIP` when the suite is already red with the model's
  change, and the source is not reverted: a suite that fails either way
  measures nothing. `asohav-07`'s second run left a test file that does not
  parse and recorded `failsOnOld: PASS` for it; 30 rows in all read
  `suite: FAIL, failsOnOld: PASS` that way (none is a pass; documented in
  `tests/results/README.md`). TSV parsers must tolerate `SKIP` in that column.
  New guard `tests/test-fails-on-old.ps1` (9 checks, PowerShell 7 and 5.1;
  fails 4 of them against the previous harness).

- Retire `asohav-05-library-write-validation` and `asohav-06-bond-cap-setting`
  (owner decision 2026-10-03). Their pins carry the asohav repo's ~280 KB
  `CLAUDE.md`, a file that existed for two days before the owner trimmed it to
  16 KB, so they measure a transient mistake that no 64k seat can see past, not
  daily use. New manifest field `retired` ({date, reason, see}): the task keeps
  its id, pin and rows; `test-tasks.ps1` and `run-tasks-batch.ps1` leave it out
  of a no-argument run, `-Tasks all` and the picker, and refuse it by name
  unless `-IncludeRetired`. The roadmap records the way back (new ids on the
  pin plus the first trimmed `CLAUDE.md`, `47bf270`) and the open question of
  how tasks should treat a repo's instruction file. Guarded by
  `tests/test-retired-tasks.ps1` (27 checks, PowerShell 7 and 5.1).
- First model run of the 18 new tasks: `qwen3.6` (desktop, Ollama 0.34.3,
  opencode 1.18.34, 64k, CPU companion), 18 runs plus a follow-up of four at an
  1800 s cap. 11 of 16 valid graded runs pass every gate; the failures are one
  test that does not catch its bug (`kane-14`), two output-cap hits (`lfc-07`,
  `asohav-09`) and two long-context losses (`kane-07` overflowed into OpenCode
  compaction, `kane-08` lost the task at 46k tokens). Four rows (`asohav-05`/
  `-06`, twice each) measured nothing: the repo's ~280 KB `CLAUDE.md` at those
  pins made the first request ~83k tokens and Ollama truncated it to 32,770,
  dropping the system prompt, tools and task. Recorded in
  `tests/results/README.md` ("Prompt truncated by Ollama") and the roadmap's
  "Task set expansion II". `test-tasks.ps1` now detects that case from the local
  Ollama log (`Get-OllamaPromptTruncation`: exit -3, `_TRUNCATED_` transcript,
  no row) and records `promptTruncation` and an engine-neutral `servingEngine`
  in every graded run JSON, ahead of the planned move off Ollama. New guard
  `tests/test-prompt-truncation.ps1` (24 checks, PowerShell 7 and 5.1).
- `opencode <profile>` from any PowerShell (owner request 2026-10-03):
  `desktop/scripts/opencode-profiles.ps1` defines an `opencode` function that
  sends a live profile name (full, or without `dev-workflow-`/`dev-`, any case)
  to `desktop/scripts/opencode.ps1` and everything else to the real opencode
  untouched; `install-opencode-profiles.ps1` adds one guarded line to the
  PowerShell 7 and 5.1 profiles (`-Uninstall` removes it). The launcher now
  unloads the desktop models the profile does not use and waits for them to go
  before warming (`-KeepLoaded` skips; profiles with no desktop seat leave the
  desktop alone), restores the shell's env when opencode exits, calls the real
  opencode explicitly, and `-ListProfiles` lists every live profile, not only
  `dev-workflow-*`. Guarded by `tests/test-opencode-profiles.ps1` (22 checks,
  PowerShell 7 and 5.1). Live: quality → resident → quality left exactly each
  profile's two models in `/api/ps`; the first try logged one `evicting` line
  because Ollama acknowledges `keep_alive: 0` before the memory is free, and
  after the wait the repeat logged none.
- `dev-workflow-quality` no longer starts the Docker dev stack at login
  (`DEV_DOCKER_STACK=false`; owner decision 2026-10-03). `qwen3.6` holds far
  more system RAM than documented: Ollama maps the whole 20.3 GB model file
  (`CPU_Mapped`), GPU part included, and the process held 16.56 GB private
  beside the companion's 2.40 GB, ~3.5 GB of 32 GB left. With the stack up
  (WSL's VM 2.1 GB) available memory fell to 0.55–1.1 GB, the model paged at
  4k–19k hard page-ins/s, and the re-run of the companion driver was killed
  for low memory 85 s into its first turn. RAM figures corrected in the
  profile header, `AGENTS.md`, `docs/profiles.md`, `docs/start-here.md`,
  `startup.ps1`'s comment and `docs/main-seat-trial.md` (new "Follow-up"
  section). Start the stack by hand with `docker-stack.ps1 up`.
- A dead job host no longer ends a task batch. On 2026-10-02 the PowerShell
  process of the background job running `opencode` died under run 1 of 16
  (`kane-01` × `devstral-small-2:24b`); `Receive-Job` raised
  `PSSessionStateBroken`, the script's `Stop` made it terminating, and the
  other 15 runs never started. Had it not thrown, the empty result would have
  defaulted to exit -1 and been archived as a `_TIMEOUT_`. `Invoke-OpencodeRun`
  (`tests/test-tasks.ps1`) now reports it as an infrastructure FAIL (exit -2,
  `_INFRA_` transcript, no summary row) and kills any orphaned opencode
  (`Stop-OrphanOpencode`, shared with the timeout path). PowerShell 7 never
  ends such a job, so the wait is now 5 s slices with a check that the job's
  PID (its first output) is alive. `tests/run-tasks-batch.ps1` also catches
  any exception out of a run, records it as `crash`, and continues. New guard
  `tests/test-opencode-run.ps1` (12 checks, PowerShell 7 and 5.1) kills the
  job's process for real; against the old code it reproduces the crash.
- Desktop keep-alive is 4h (User env `OLLAMA_KEEP_ALIVE=4h`, owner decision
  2026-10-03; was Ollama's 5m default, under which an idle `qwen3.6` reloaded
  and re-prefilled for 2–3.5 min). Confirmed live as `OLLAMA_KEEP_ALIVE:4h0m0s`
  in `server.log` after a restart. `desktop\scripts\opencode.ps1` now
  pre-loads the profile's desktop main seat in the background at launch
  (`-NoWarm` skips it). It warms the main seat only: warming the CPU companion
  as well let it load first, and `qwen3.6`'s load then evicted it, so it
  loaded twice; cold-start test after the fix: 0 evictions, both models
  expiring 4h out. Recorded in `AGENTS.md` (Gotchas), the quality profile,
  the roadmap's decision list and `tests/results/README.md` ("Era
  confound": durations across the date are not comparable; verdicts are).
- Re-seat `dev-workflow-quality`: the main seat is `qwen3.6:35b-a3b-coding`
  (was `qwen3:14b`, seated 2026-09-17) and the small model is
  `qwen2.5-coder-3b-cpu` (was `qwen2.5-coder:3b`), per the main-seat trial
  and its companion experiment (`docs/main-seat-trial.md`). `startup.ps1`
  derives the companion from the 3b with `num_gpu 0` (`$derivedModels`, after
  the context bakes) and lists it in its context contract;
  `DEV_DESKTOP_MODELS` gains `qwen3.6`; `test-profiles.ps1`'s intent manifest
  moves with the profile. `AGENTS.md`, `docs/profiles.md`,
  `docs/start-here.md`, `docs/troubleshooting.md`,
  `docs/model-architecture.md`, the roadmap's standings label and the model
  comments and display names in `opencode/global/opencode.jsonc` now name
  the new seat; dated history is unchanged. Not measured: the pair beside a
  game, and beside the Docker dev stack (the experiment ran with WSL
  stopped).
- Close the main-seat trial and pre-register its second experiment
  (`docs/main-seat-trial.md`). `qwen3.6:35b-a3b-coding` meets the re-seat
  bar (zero FAILs, three CLEANs; the control can reach two at most), so the
  four open cells were not run. The trial-day Ollama logs show `qwen3.6`
  spills to system RAM and takes every GPU byte, the 3b companion runs once
  per session (titles) and evicts it then, and keep-alive reloads cost more
  (2–3.5 min first replies). Option B (a 32k re-measure) is ruled out; option
  A, the same 3b pinned to the CPU (`qwen2.5-coder-3b-cpu`, registered in
  `opencode/global/opencode.jsonc`, built by hand), runs first against a
  five-criterion pass bar on a clean desktop; option C, documented eviction
  acceptance, is the fallback. No profile changes until it passes.
  `OLLAMA_KEEP_ALIVE` is added to the roadmap's owner decisions.
  **It passed, 5 of 5 (2026-10-03):** across three sessions (15 turns) no
  eviction, `qwen3.6` loaded once and kept 12.51 GB of VRAM throughout, the
  companion stayed at 0 GB VRAM, and titles took 3.4 to 14.8 s. Driven with
  `opencode run` instead of the TUI (owner away), recorded as a deviation.
- Add 18 benchmark tasks mined from the owner's repos, so the suite is 27:
  `kane-07` to `kane-14`, `lfc-04`, `lfc-05`, `lfc-07` and `asohav-03` to
  `asohav-09` (the 15 candidates that fit the harness plus `kane-14`, `lfc-07`
  and `asohav-05`, which needed the multi-file `srcRevertFiles` fix). Each is a
  real merged fix pinned at its fix commit's parent, and 15 carry an
  `acceptance` block whose oracle is the upstream fix commit's own test file.
  New shapes: two-source-file fixes, brand-new test files, spec reversals,
  React component and hook tests, a symptom-only data-conformance prompt. Every
  entry ran through the real `test-tasks.ps1` with a stand-in `opencode` in a
  fresh worktree: the baseline equals `baselineExpect`, the upstream tests fail
  on the untouched base, the reference fix passes every gate, the fix without
  tests fails failsOnOld, the tests without the fix fail scope and suite, and
  the gate results are identical across four environments and three repeats.
  `asohav-05`, `asohav-07` and `asohav-08` pin `DATABASE_URL` (the `asohav-02`
  rule). `docs/roadmap.md` → "Task set expansion II" has the table, the parts
  the upstream tests do not pin, and the 11 candidates not added.
- failsOnOld no longer uses `git stash`. `refs/stash` belongs to the repository,
  not to a worktree, so two tasks of one repo graded at the same time popped
  each other's stashes (found independently by three of the agents validating
  the new tasks: `stash pop failed`, then an acceptance run against reverted
  source). `Invoke-WithSourceReverted` saves the model's source bytes, checks
  the files out of the pinned base (not `HEAD`, so a model that commits still
  reverts to the pin) and writes the bytes back, touching nothing outside the
  worktree. The gate verdicts were already decided before the pop, and the six
  same-repo overlaps in the corpus (2026-09-23, `kane` tasks) finished at least
  85 s apart, so no recorded verdict is known to be affected.
  `tests/test-revert-source.ps1`, 46 checks (one-file, two-file and bare-string
  `srcRevertFiles`, non-text bytes restored byte for byte, a path the base
  lacks, a model that committed, two worktrees of one repo held open together),
  replaces `test-stash-args.ps1`; six mutants of the mechanism (the old stash,
  nested-array arguments, a text restore, `HEAD` instead of the pin, no restore,
  a revert that reaches the tests) each fail it. A second battery of the 18 new
  tasks against the new harness ran six lanes at once, two per repository, and
  reproduced all 72 runs of the first (the sequential one) exactly.
- Harness: a pinned acceptance commit this clone does not have yet is fetched
  from `origin` once before it is called missing (`Resolve-AcceptanceCommit`,
  as `Resolve-TaskBase` already did for a base), and `run-tasks-batch.ps1
  -SetupOnly` fetches for it too. Groundwork for tasks mined from upstream fix
  commits, whose acceptance oracle is the fix commit's own test file: it is on
  `origin/main` but not necessarily in an older clone. `test-task-pins.ps1`
  gains five checks (a base pin and an acceptance pin that are upstream but not
  yet local, an acceptance pin that exists nowhere; the acceptance ones fail
  against the previous harness) and its real-checkout step now resolves pins
  through the harness's own resolvers. `test-task-env.ps1` gains a guard that
  every ASoHaV `apps/server` task pins `DATABASE_URL` (`asohav-01` is exempt:
  it pre-dates the rule and its recorded rows do not depend on it).
- `Get-PublishState` (`run-tasks-batch.ps1`) sets `$ErrorActionPreference =
  "Continue"` for itself. Its git probes write to stderr in normal operation (a
  commit origin lacks is "not our ref"; a local origin warns that it ignores
  `--filter`), and under a caller's `"Stop"` Windows PowerShell 5.1 turns that
  into a terminating error. The batch itself runs under the default, so the
  real `-SetupOnly` was unaffected; `test-task-pins.ps1` (which sets `"Stop"`)
  failed on 5.1 at "a commit that was pushed", and passes on 5.1 and 7 now.
  Found by the first run of the regression tests on Windows PowerShell 5.1.
- Pin each benchmark task's test environment. `tests/tasks/manifest.json` gains
  an optional `testEnv` (variable → value, `null` = unset) that `test-tasks.ps1`
  applies to the test command and to the model's own `opencode run` process,
  restores afterwards, and records in the run JSON (`Set-TaskTestEnv` /
  `Restore-TaskTestEnv`, used by `Invoke-Test` and around the `opencode` call).
  `asohav-02` pins `DATABASE_URL` to unset: a model-written test that imports
  the real `repo.ts` imports `pgPool.ts`, which throws at import without it, and
  the harness process had the variable on 2026-09-29 but not on 09-27, so the
  two `qwen3.6` passes of 09-29 load only where it is set. `lfc-02` pins
  `MANAPOOL_API_KEY` to unset (the flake its prompt already warns about). New
  `tests/test-task-env.ps1`, 50 checks: the manifest entries, the real
  set/restore functions and `Invoke-Test`, and the real `test-tasks.ps1` run end
  to end against a fixture repo with a stand-in `opencode` (three tasks in one
  run: the model's process, the gates and the run JSON see the pins, and the
  next task does not). Sixteen mutants (scratch copies) each fail it.
- Record a second replay of DP12's 12 passes (`docs/implementation-tasks.md` →
  DP12 addendum), this time with the gates re-run and the project's own fix
  commit as an oracle. All 12 gates reproduce and all 12 sources are right
  against tests the models never saw; three of DP12's classifications differ
  (kane-04 × `qwen3.5` rep 1 asserts no warning, both lfc-03 passes never test
  `expired`, both asohav-02 passes need `DATABASE_URL`), so 5 clean and 7
  qualified rather than 10 and 2. `docs/roadmap.md` carries the consequence for
  the `qwen3.6` lead: 12/15 and Fisher p = 0.30 over `qwen3.5` if the asohav-02
  passes are counted as a clean checkout would count them.
- Main-seat trial: control task 3 FAIL (`qwen3:14b` on `9060ae9`, same base
  as the candidate: edit-first, false truncate claim over dead code, an
  unprompted reject→truncate contract change with the specifying test
  rewritten to fit, and a self-contradictory suite report against a real
  356/356). Control stands at 0 CLEANs across tasks 1 and 3, so the
  candidate's bar clearance (3 CLEANs, 0 FAILs) no longer depends on any
  outstanding cell. Remaining: control tasks 2 + 4, `qwen3.5` tasks 2–4,
  then the second experiment's pre-registered pass bar.
- Main-seat trial: all four `qwen3.6` cells graded (task 1 CLEAN, task 2
  CLEAN on the corrected `170b395` base after a VOID run on `4906dc2`,
  task 3 QUALIFIED, task 4 CLEAN with a retracted fixture-trap claim).
  Session rows in `docs/main-seat-trial.md`; control cells still open.
  Parks the alert-first TUI session watchdog (`docs/implementation-tasks.md`
  item 10): the task-4 session stalled 6+ min mid-loop needing a manual
  kick, and batch timeouts already cover non-interactive runs.
- lfc-03's acceptance commit `3215aaf` is published
  (`bench/status-guard-throw` pushed to `mkane848/lfc-bot`; a from-scratch
  fetch resolves), so every benchmark pin is on GitHub. Corrects the
  "local-only" wording in this changelog, `AGENTS.md` and `docs/roadmap.md`.
- Record data point 12 (`docs/implementation-tasks.md`): replay audit of the
  12 unaudited N>1 passes (PRs #62–#64), closing DP11's caveat. 10 genuine
  and spec-complete; 2 qualified with grades standing (lfc-02 × `qwen3.5`
  rep 1 ships a hardcoded `0.0.0` User-Agent version against a real 1.5.0,
  rep 2 deletes a used type import into a typecheck-SKIP task). No hollow
  passes; the standings are strengthened, not revised.
- Pin every benchmark task's base commit, so a moved branch cannot change a
  base under the corpus. `kane-01`, `lfc-01` and `lfc-03` ran from the tip of a
  local branch (a work branch, and `main`); every recorded row had happened to
  use one commit per task, and those are now `benchBaseCommit` in
  `tests/tasks/manifest.json`, with `bench/*` branch labels like the other six.
  - `test-tasks.ps1` `Resolve-TaskBase`: the worktree is made from the pinned
    SHA, not from `refs/heads/<branch>`. A local branch elsewhere is a WARN; a
    pin missing from the repo is an error naming the `git push` that fixes it; a
    task without a pin still uses the branch tip.
  - `run-tasks-batch.ps1 -SetupOnly` warns when a pinned base or lfc-03's
    acceptance commit is not on origin (`Get-PublishState`), with the push
    command. `git ls-remote` and a by-SHA fetch into an empty repo show **all
    nine pinned bases are on GitHub**: eight on `main`, `kane-01`'s `92a8ed0` as
  `review-gate/deck-validity` and PR #82's head. lfc-03's acceptance commit
  `3215aaf` (`bench/status-guard-throw`) was the one local-only pin — pushed
  2026-09-30 (`git -C M:/Projects/LFCbot push origin bench/status-guard-throw`;
  a from-scratch fetch of the SHA resolves), so every pin is now on GitHub.
  - lfc-03's acceptance tests are pinned by `acceptance.commit`
    (`Resolve-AcceptanceCommit`): all 18 recorded acceptance runs used
    `3215aaf`, and a branch that has moved is a WARN, not followed.
  - The first version of this entry said `kane-01`'s base was local-only. That
    was wrong: the check ran in single-branch clones, which show `main` only.
    `Get-PublishState` now asks origin itself from an empty scratch repo,
    because `git fetch origin <sha>` inside a clone that already has the commit
    exits 0 without asking anyone; it also finds a commit only a pull-request
    ref reaches.
  - New `tests/test-task-pins.ps1` (42 checks): manifest pins, all 218 rows and
    all 18 acceptance runs used them, and the three functions on throwaway repos
    (including the two shapes that fooled the first version); it fails on 14
    mutants. `AGENTS.md` and `docs/roadmap.md` (the 2026-09-30 correction, the
    setup section) updated.
- Hold benchmark replicates to one opencode version and spread them across time.
  opencode installs patch releases by itself when a TUI starts (never from
  `opencode run`; read from upstream at `2fa3363`), and the results corpus took
  1.18.31, .32 and .33 in ten days. Split by version, all 8 disagreeing
  replicate pairs are cross-version (8 of 19; 0 of 11 back-to-back, 0 of 2
  same-version other-session), so version cannot be told from session.
  - `docs/adversarial-review-2026-09-29.md` §7: a same-config attempt shares
    prompt sha, `numCtx`, Ollama version **and** opencode version.
  - `run-tasks-batch.ps1`: reps run rep-outer within each model (`-BackToBack`
    for the old order); the batch reads `opencode --version` at the start and
    stops if it changes; the preflight reports whether autoupdate is pinned.
    New `tests/test-batch-plan.ps1` (27 checks; fails on seven mutants).
  - `opencode/global/opencode.jsonc`: `autoupdate` `true` → `"notify"`. **The one
    behavior change:** OpenCode no longer upgrades itself; run `opencode upgrade`
    on purpose, between batches. Revert that line to keep autoupdate on; the
    drift stop still protects a batch.
  - `docs/roadmap.md` → "By opencode version": the seat order is the same on
    both versions (`qwen3.6` 8/9 then 6/6, `qwen3.5` 7/9 then 6/12, `qwen3:14b`
    2/9 then 0/4); on the frontier cells at 1.18.33 `qwen3.6` is 6/6 to
    `qwen3.5`'s 2/6 (p = 0.061). No seat decision moves.
  - New `docs/references.md` rows for the opencode source and docs read.
- `test-tasks.ps1`: the writes gate tells an output-cap hit from liar mode. An
  exit-0 run with no write whose last step is an empty `length` step at
  `limit.output` (no text, no tool call) is reported as "NOT liar mode: the
  seat ran out of room to act", and the run JSON records `outputCapHit`,
  `finishReason`, `lastStepOutput` and `outputLimit` (read from `opencode debug
  config`; an unreadable limit degrades to "cannot confirm a cap"). Both are
  still FAILs, and the `tasks-summary.tsv` schema is unchanged. A `length`
  stop that cannot be confirmed as the cap (limit unreadable, or the stop came
  below it) gets its own "truncated" message instead of the liar-mode one. A
  run that makes edits and then hits the cap keeps its PASS, with a note. New
  `tests/test-cap-hit.ps1` runs the real functions and the real gate block on
  synthetic transcripts and 8 committed ones the 2026-09-29 audit classified;
  it fails on eight mutants (four of the classifier, four of the gate wiring).
  A scratch re-derivation over all 31 exit-0 zero-write rows gives the audit's
  split (8 cap hits, 23 genuine). Also fixes two docs that still called
  `ornith:9b`'s cap hits liar mode (`docs/target-setup.md`,
  `docs/implementation-tasks.md`).
- `test-tasks.ps1`: grade tasks that list two or more `srcRevertFiles`. The
  failsOnOld revert built its `git stash push` arguments with the file list
  nested inside the array; `Run-Native`'s `[string[]]` parameter joined it into
  one argument (`a.ts b.ts`), git rejected the pathspec, and every model would
  have got "git stash push failed - cannot grade" on such a task. All nine
  current tasks list one file, so it never fired. New
  `tests/test-stash-args.ps1` runs the real line against a throwaway repo (one
  file, two files, bare string); it fails on the old code and passes now.
- Correct claims the data no longer supports (docs and comments only, no
  behavior change), from a recheck against `tests/results/`:
  - "Only the qwen3 family can call tools / 5 of 13 pass" (`AGENTS.md`,
    `README.md`, `docs/start-here.md`, `docs/troubleshooting.md`,
    `docs/profiles.md`, `docs/model-architecture.md`, two profile comments, two
    test-script comments): 13 of 22 probed models pass (Ollama 0.34.2/0.34.3), and a
    probe PASS is necessary, not sufficient (`lfm2.5:8b` passes, then makes zero
    writes on 8 of 8 tasks). `AGENTS.md` also says the configured main seat is
    not the best-measured one.
  - Stale `num_ctx` figures in `AGENTS.md` and `README.md` now match
    `startup.ps1` `$contextModels` (65536 for six seats, 32768 for the qwen3
    pair and devstral pair).
  - `tests/results/README.md`: update banner (218 rows, 81 passes), an
    opencode-version era axis, a correction that the control rematch ran, and a
    correction that 8 of the 31 zero-write rows since 2026-09-22 are output-cap
    hits (`nemotron` 4/6, `ornith` 3/4, `qwen3:8b` 1/1), not liar mode.
    `AGENTS.md` Gotchas gains the same warning.
  - `docs/roadmap.md`: the source repos are public (not "private"); the
    `bench/*` branches are local-only (not "verifiable by anyone"); a status
    note on the 2026-09-23 "Next up" list.
  - `docs/adversarial-review-2026-09-29.md`: dated addendum correcting five
    statements against the raw rows (control rematch had run, task difficulty
    figures were the 09-23 inventory, liar-mode list, N=1 confirmed,
    protocol config key).
- Record data point 11 (`docs/implementation-tasks.md`) and the same-config
  executor standings (`docs/roadmap.md`): the adversarial review's N>1
  protocol on the frontier cells (PRs #61–#64, desktop Ollama 0.34.3). Counted
  on one config (prompt sha, designed `numCtx`, timeouts as attempts),
  `qwen3.6` passes 14/15 attempts, `qwen3.5` 13/21, `qwen3:14b` (the default
  main seat) 2/13; `qwen3.6` against `qwen3.5` is Fisher p = 0.051, against
  `qwen3:14b` p = 0.0001.
  - None of the 9 graded FAIL rows is a zero-write. Of the 18 lfc-03 runs with
    an owner acceptance result, 12 pass it and 8 pass every gate.
  - Replicates are not independent evidence: back-to-back pairs agreed 11 of
    11, pairs from different batches disagreed 8 of 21 (p = 0.03), and every
    mixed cell straddles opencode 1.18.32 and 1.18.33.
  - The replay audit of the 12 new passes was not done. No seat or config
    changes.
- Adversarial review of the testing methodology
  (`docs/adversarial-review-2026-09-29.md`): what each harness measures,
  N=1 / era-confound / guided-repair limits, plus the N>1 protocol
  (frontier tasks × top-2 challengers + control, 2 fresh reps each,
  per-attempt reporting, no seat decisions until it reports).
- Record data point 10 (`docs/implementation-tasks.md`), two decision tests
  for open seat questions.
  - north-mini, 32k vs 64k on lfc-01: 0/4 PASS, and no `/workspace` at
    either size. Context size isn't the fix.
  - Write-discipline canary: `qwen3.6` and `qwen3.5` 3/3, `qwen3:14b` 2/3
    (one double write). `qwen3.6` waits about 2 minutes before the first
    reply of every session.
  - Corrects DP9's north-mini count: `/workspace` in 4 of 9 runs at 64k, not
    3 of 5.
  - New `tests/results/reliability-summary.tsv`, plus 3 graded runs, 1
    timeout transcript and 3 `tasks-summary.tsv` rows. The temporary
    `north-mini-code-1.0-32k` tag is removed.

- Record data point 9 (`docs/implementation-tasks.md`): step 6's other 6
  tasks × 8 desktop seats (six at 64k, the qwen3 control pair at 32k).
  **26/48 PASS**; 64k seats 24/36, 32k seats 2/12. Across all 9 tasks:
  `qwen3.6` 8/9, `qwen3.5` 7/9, `qwen3:14b` (the default main seat) 2/9.
  - All 26 passes were audited beyond the gates. No test was removed, and 3
    passes met the gates while covering less than the prompt asked.
  - New ungraded shape: an output-cap truncation that ends in the Qwen
    template 400 without any compaction.
  - 64k passes ran a median 37% faster than matching 32k passes.
  - 86 result files, 5 timeout/infra transcripts and 43
    `tasks-summary.tsv` rows are archived.
  - `docs/roadmap.md` gains "Executor standings after step 6", with the
    re-seating case and its preconditions. Nothing is re-seated yet.

- Retire LM Studio. VS Code's BYOK registry now has one provider, desktop
  Ollama, with every desktop seat (the 10 tool-capable seats + the
  `deepseek-r1:14b` reviewer), budgets mirrored from `opencode.jsonc`
  (`maxInputTokens` + `maxOutputTokens` = served `num_ctx`; the old
  entries declared the whole window as input). `docs/lmstudio-vscode.md` is
  now `docs/vscode.md`, rewritten Ollama-only; links and current docs
  updated; dated 2026-09-18/19 run records still say what they ran on.
  `opencode.jsonc`'s three import comments now say "local GGUF" instead
  of LM Studio.

- 64k context trial: `qwen3.5:9b`, `qwen3-coder:30b-a3b`, `north-mini-code-1.0`,
  `laguna-xs-2.1`, `qwen3.6:35b-a3b-coding` and `nemotron-3.5-lightning` go to
  65536 in `startup.ps1` `$contextModels`, `opencode.jsonc` `limit.context`
  and `models/catalog.tsv`. The devstral pair and the qwen3 dense pair stay at
  32768. Acceptance rule in `docs/roadmap.md` → "Context budget".
- `test-tasks.ps1`: stamp `numCtx` (the served model's baked `num_ctx`, from
  `/api/show`) into every result JSON and the header line, so runs at
  different context sizes can be told apart.
- Record data point 8 (`docs/implementation-tasks.md`): the 64k trial re-ran
  lfc-03, kane-02 and asohav-02 on the six raised seats — **9/18 PASS vs 3/15
  at 32k** for the same seats; timeouts 3 → 1, context deaths 3 → 1. First
  local asohav-02 passes (`laguna-xs-2.1`, `qwen3.5:9b`). All 9 passes
  audited beyond the gates (no assertion removed); lfc-03's two typecheck
  WARNs reproduced (laguna: a real `string`-index error in source;
  qwen3-coder: test-only). Roadmap acceptance criterion met; 64k adopted for
  the six seats. 34 result files + 16 `tasks-summary.tsv` rows archived.

- Record data point 7 (`docs/implementation-tasks.md`): step 6's frontier
  slice — lfc-03, kane-02 and asohav-02 × the desktop seats. First local
  passes: lfc-03 2/8 (`laguna-xs-2.1`, `qwen3.6:35b-a3b-coding`, both 29/29
  owner acceptance), kane-02 1/9 (`laguna-xs-2.1`); asohav-02 stays 0/14.
  Three more lfc-03 seats wrote an acceptance-correct fix but failed a gate on
  their own tests. Four ungraded runs were context overflow (OpenCode
  compaction), not infrastructure. Memory-pressure-contaminated timeouts are
  marked superseded. 36 result files, 13 timeout/infra transcripts, 18
  `tasks-summary.tsv` rows archived.
- `test-tasks.ps1`: create the transcript file before the run starts, so a
  timeout with zero events leaves an empty `_TIMEOUT_` transcript instead of
  nothing; decode opencode's stdout as UTF-8 inside the job (non-ASCII text
  in transcripts was OEM-codepage mojibake).
- `docs/roadmap.md` → "Context budget: 32k vs 64k per seat": measured KV,
  CPU offload and generation speed at both sizes for the 10 desktop seats.
  Hybrid/SWA/MoE seats cost under 1 GB; the dense `devstral` pair loses ~30%
  generation speed; `qwen3:8b`/`qwen3:14b` are capped at 40,960 by their
  training context. Trial proposed, not adopted.

- Record data point 6 (`docs/implementation-tasks.md`): oracle sweep —
  `opencode-go/qwen3.8-max` PASSes all 8 remaining manifest tasks on the same
  prompt shas as the local corpus (9/9 with DP5). Every task is passable as
  written; kane-02, asohav-02 and lfc-03 still have no local PASS. Test diffs
  audited beyond the gates (kane-01's removed lines strengthen the PR #82-trap
  test). 16 result files + 8 `tasks-summary.tsv` rows archived.
- `docs/roadmap.md` → fine-tuning: replace the stale "zero successful
  trajectories" gate with the current state (9 oracle trajectories, 22 local
  PASSes) and the next gate — a held-out split, since training on the 9
  benchmark tasks and grading on them would measure recall, not capability.

- Record blind-trial data point 5 (`docs/implementation-tasks.md`): Accelerator
  A — `opencode-go/qwen3.8-max` on `lfc-03-status-transition-guard`, same
  prompt sha as DP4's write arm (`4A1266C4478E`) — **PASSes all four gates**
  (3 writes, 320 s, suite 30/30, fails-on-old catches all 5 forbidden
  transitions, typecheck clean) and 29/29 on the owner's acceptance tests.
  Step 5's DoD is met. Result files + one `tasks-summary.tsv` row archived.
- Owner acceptance tests for `lfc-03` (`LFCbot` `bench/status-guard-throw` @
  `3215aaf`, on GitHub since 2026-09-30) assert the prompt's error contract — id, current
  and requested status in the message — instead of a `/cannot .* from/`
  phrasing that failed a spec-compliant guard with other wording.
- `test-tasks.ps1`: informational owner-acceptance check. A task's
  `acceptance { ref, files }` block is swapped in over the model's tests after
  the four gates and the model's files are restored byte for byte; the result
  (status, ref, exact commit) lands in the per-run JSON only — never a gate,
  TSV schema unchanged. Under `-DryRun` those tests must fail on the untouched
  base. `lfc-03` carries the block.
- `test-tasks.ps1` harness honesty (step 8a/8c): transcripts stream to disk as
  events arrive, so a timeout keeps a `_TIMEOUT_` transcript; orphaned
  `opencode` children are tree-killed on timeout; the closing line reports the
  real appended-row count instead of always claiming "Summary appended"; the
  `ollamaVersion` field is the serving host's `/api/version` (`n/a` for hosted
  providers) instead of the local binary.
- `tests/tasks/manifest.json`: drop a trailing comma after `lfc-03`'s prompt
  that strict JSON parsers rejected (PowerShell 7 tolerated it).

- Record blind-trial data point 4 (`docs/implementation-tasks.md` → "New open
  follow-ups"): the first `lfc-03` executor attempt through the harness.
  Accelerator B delivered as `-EditFormat write|edit` on `test-tasks.ps1`.
  Both A/B arms on `ollama-desktop/qwen3:14b` FAILed: arm A (write) made the
  guard change (scope/suite green, one whole-file `write`) but never authored
  acceptance tests — **fails-on-old FAIL**, the exact trap DP4 documents; arm
  B (edit) timed out at 1800 s and its transcript was again unarchived (the
  "Summary appended but appends nothing" gap). Corpus: two result files +
  one `tasks-summary.tsv` entry archived. Step-5 DoD met on execution but NOT
  on grade — Accelerator A (the `opencode-go/qwen3.8-max` oracle run of the
  exact order) is queued with owner approval 2026-09-25.
- Add `-EditFormat write|edit` to `tests/test-tasks.ps1`: appends a whole-file-
  write vs substring-search-replace directive to the task prompt (part of the
  hashed prompt, so each arm records a distinct sha). Implements the
  edit-format A/B accelerator (`docs/methodology-research.md`); the first A/B
  executor attempt on `lfc-03-status-transition-guard` is docketed.
- Record blind-trial data point 3 (`docs/implementation-tasks.md` → "New open
  follow-ups"): Plan mode killed the live-checkout violation but stalled the
  seat — contract step 4 needs a write (the only one in the whole prompt), Plan
  mode denies it, and `qwen3.6` resolved the contradiction by compacting 5×
  into the forbidden summary template and asking new questions instead of
  emitting `## Work orders`. Resolved by drafting the order outside the seat:
  the DP3 interview answers become the `lfc-03` contract, docketed below.
- Docket the first real step-5 work order as a new task
  `lfc-03-status-transition-guard` (`tests/tasks/manifest.json`): a
  status-transition matrix for LFCbot `setStatus` that supersedes the
  silent-no-op contract of `lfc-01` (only `active` may originate a terminal
  transition, `fulfilled → deleted` stays legal, everything else throws per
  `createListing`'s convention). Acceptance block authored + verified
  failing-first outside the seat on LFCbot bench branch
  `bench/status-guard-throw` (`fcf9d1a`): 24/29 on unguarded `main` (baseline
  21 kept green), 29/29 with a candidate guard, full suite 343/343, scoped
  tsc clean. `lfc-01` keeps its older contract and history.
- Add `docs/references.md` (catalog of every external source cited in the docs
  + the citation convention) and `docs/methodology-research.md` (2026-09-24
  sanity-check writeup: methodology verdict, two accelerators — spend the
  hosted-calibration key and run the edit-format A/B — and community resources
  mapped to the measured gaps: SWE-Edit, aider edit-format analysis, the QCoda
  engine-model bake-off, terminal-agent context management). `AGENTS.md` now
  requires inline citations for externally-grounded claims and a
  `docs/references.md` row in the same change; `docs/README.md` indexes both
  new pages.
- Rewrite `docs/implementation-tasks.md` step 5 as "blind trial v2"
  (2026-09-24): data points 1+2 consumed, the `ses_f2ef…` recovery thread is
  void, and the launch is Plan-mode-first (Step 0 — the DP2 mechanical fix).
  Owner locked three decisions: target = DP2's own finding (the `setStatus`
  guard at `listings.ts:297-301`), calibration key spent on the produced order
  once it exists (accelerator A), and the edit-format A/B packaged as the
  first executor attempt (accelerator B).

- Expand `docs/implementation-tasks.md` → "Next steps" into the ordered
  2026-09-24 plan (steps 5–9, each with a definition of done): blind trial
  first (recover `ses_f2ef…` with the mission line, small target,
  failing-first acceptance), then control rematch + 1800 s offloader reruns
  on disjoint task sets, `qwen3.5:9b` to N=3 + node3 Q4 probe-then-batch,
  harness honesty fixes before the next results PR (streamed `_TIMEOUT_`,
  kill-vs-cap tags, per-host version stamp), greenfield slice chain last.
  Items 1–4 kept as completed record.

- Bind the `qwen3.6` planner prompt (`docs/agent-notes/planner-prompt-qwen3.6.md`)
  to a mandatory mission line after its first live run stalled (blind-trial
  data point 1, recorded in `docs/implementation-tasks.md`): launched with no
  `Target repo:`/`Target:` line, the session treated the workflow repo itself
  as the target — 23 messages, 4 compactions, zero work orders, LFCbot never
  read. The build must now open with a two-part mission line; the explore step
  is bound to that repo only; re-reading a file already in context is banned
  (the 32k filled in <30 min largely on 3-4x re-reads of three docs); status
  replies are short lines, not full-session summaries (the model started
  echoing the compaction summary format after the first compaction). The live
  session is recoverable without a restart — reply to it with the mission line.
- Decide the scaffold-from-scratch benchmark shape (roadmap.md): plan **B,
  decomposed slices** for the React 9 + TS webapp-from-plain-English case.
  Feature slices fit the existing four gates untouched (benchBaseCommit =
  previous slice's head; failsOnOld reverts the slice's source); the slice-0
  skeleton is a planning-time artifact because the scope gate requires a
  revertable source file, and a greenfield reverting-scaffold task-kind is
  explicitly deferred. The translator seat is the planner — decomposing the
  English prompt into ordered, benchmark-shaped slices is its existing
  contract. First instance queued behind the blind-trial lanes
  (implementation-tasks.md → "New open follow-ups").
- Rerun the 3 open timeout unknowns at a 1800 s cap (2026-09-23 evening,
  `-OnlyMissing` re-targeted the row-less cells): `qwen3.6 x asohav-01` PASS
  (13 writes, 1620.3 s, suite 48 green - the seat's first pass on the cell),
  `qwen3.6 x asohav-02` FAIL liar mode (exit 0, 0 writes); the "times out at
  1800 = seat finding" branch resolves negative - the seat finishes, it just
  fails the cell. `node3 qwen3:8b x lfc-02` was killed by a human from
  another session at ~25 min (exit -1: a kill, not a cap), so the
  closeout's "hangs again = host finding" branch is NOT met and the cell
  stays open; the harness-tagged `_TIMEOUT_` transcript was renamed by hand
  to `_ABORTED_` for truthfulness (new open follow-up: the harness cannot
  distinguish a kill from a cap). Corpus 102 -> 107, passes 21 -> 22;
  `tests/results/README.md` re-inventoried to 107 (absorbing PR #45's 3
  graded rows that the 102-row pass had missed). Details in
  `docs/implementation-tasks.md` -> "Rerun lanes".
- Draft the `qwen3.6` planner prompt in
  `docs/agent-notes/planner-prompt-qwen3.6.md`: read-only explore first,
  one numbered-list interview, work orders shaped to fit the benchmark
  (bench branch, 2-3-file scope, testCmd), planner-written acceptance tests
  that must fail on current code before the order queues. DRAFT - not yet
  run in a live session.

- Agree the Stage 1 starting build (2026-09-23, server down): planner
  `qwen3.6:35b-a3b-coding` (fully local loop, first plans small and
  benchmark-shaped), executor attempt 1 `qwen3.5:9b` Q8 as measured (5/6),
  attempt 2 `laguna-xs-2.1` (3/3), parallel attempt `qwen3:8b` on node3,
  review-side `nemotron-3.5-lightning` (reviewer-seat trial per the round-3
  protocol — the seat is empty, auditor duty meanwhile), dispatcher manual.
  `ministral-3:8b` (0/7), `lfm2.5:8b` (0/8) and `ornith:9b` (1/7, liar mode
  2026-09-23) are out as executors. Recorded in `docs/target-setup.md` →
  "Starting build".
- `opencode/global/opencode.jsonc`: raise the `qwen3.6:35b-a3b-coding` seat to
  `limit.output` 8192 (it plans now — multi-order work orders plus acceptance
  tests do not fit the 4096 executor budget that truncated `qwen3:14b`).

- Record the aborted 2026-09-23 2-lane executor launch in
  `docs/implementation-tasks.md` (open follow-ups): Lane 1 control and Lane 2
  node3 gap fill both picked `kane-02` within 18 seconds — `-OnlyMissing`
  correctly ignored the legacy exit-1 rows while control legitimately re-ran
  the task, and no guard covers worktree contention. Zero corpus impact (102
  rows, clean tree). Adjustments before relaunch: static task partition per
  lane, driver-stop-plus-process-check stop procedure (a stopped driver
  orphans its `opencode run` child), and the two voided `kane-02` cells stay
  open.
- `tests/run-tasks-batch.ps1`: add `-RunTimeout`/`-CommandTimeout`, forwarded
  to every `test-tasks.ps1` invocation (0 = its 900/300 defaults). The
  18–25 GB offloading seats need 1800 or they die at the default cap with no
  transcript — the gap-fill review's largest failure class. Requested there,
  applied here.
- Re-inventory `tests/results/README.md` for the 102-row corpus (was 43 rows /
  1 pass): 21 genuine passes listed, an era-confound box (no desktop qwen3 row
  exists post-09-22, so incumbent-vs-challenger comparisons span three harness
  fixes), guided-repair labeling for what the tasks measure, a task × model
  coverage grid, the `lfm2.5:8b` 8/8 zero-write finding, and reconstructed
  timeout counts with the lost-transcript caveat. Defers per-attempt rates to
  `docs/implementation-tasks.md` → "Gap-fill batch review" instead of
  duplicating them.
- Reframe `docs/roadmap.md` and `docs/target-setup.md` around the owner's
  2026-09-23 decisions: executor selection winners-first (N=10 backfill and
  16-task expansion wait until after first real use; misses read as role-fit,
  not model quality), TypeScript-only until first real use, server-centric
  fleet with desktop/node3 overflow, hosted calibration unscheduled with the
  OpenCode Go key available. Roadmap Next-up item 2 replaced, node3 and
  review-gate items closed out with pointers, `target-setup.md` data section
  re-based off the gap-fill review (retiring the pooled 7%), machine roles
  record the CPU asymmetry (server serves, node3/desktop run worktrees).
- Grade the 2026-09-23 gap-fill batch (`docs/implementation-tasks.md` →
  "Gap-fill batch review"). Rates are now per attempt, because timeouts
  leave no row and graded-only ratios overstate: `qwen3.5:9b` 5/8,
  `laguna-xs-2.1` 3/8 (5 timeouts), `nemotron-3.5-lightning` 3/8,
  `qwen3.6:35b-a3b-coding` 3/8, `north-mini-code-1.0` 1/8,
  `devstral-small-2:24b` 1/8 (7 timeouts). An audit of the transcripts of all
  17 passes finds none hollow: real edits to both source and test, and every
  `failsOnOld` is a behavioural failure, not an import crash. Records the
  lost-timeout-transcript bug, the `kane-02` compaction failures behind both
  `_INFRA_` runs, and the missing Ollama-version control. Nothing else changes.

- Task-veracity benchmark: gap-fill batch 2026-09-23, 41 graded runs (22
  desktop + 19 node3) across the new executor candidates, evidence committed
  verbatim (per-run `.json` + `.jsonl`; 2 extra `_INFRA_` transcripts with no
  row, by design). Desktop candidates land guided-repair passes where
  `qwen3:8b` mostly didn't — `laguna-xs-2.1` 3/3, `qwen3.5:9b` 5/6,
  `nemotron-3.5-lightning` 3/4, `qwen3.6:35b-a3b-coding` 3/6,
  `north-mini-code-1.0` 1/2, `devstral-small-2:24b` 1/1. Node3 small
  candidates mostly miss — `lfm2.5:8b` 0/8, `ministral-3:8b` 0/5, `ornith:9b`
  1/6 — consistent with `docs/hardware.md`'s "likely too weak to write fixes"
  note on `lfm2.5:8b`. Includes the 18-row 0.34.3/0.34.2 toolcall probe log
  behind the 8 new `run-tasks-models.tsv` seats.
- `tests/run-tasks-batch.ps1`: add `Probe` and `Both` modes on top of the
  data-driven pickers. Probe runs `test-toolcalls.ps1` on every host that
  answers. `Both` then batches every seat whose probe PASSes on its host's
  current Ollama version. `-OnlyMissing` runs only task × model pairs with no
  graded row. `-Mode/-Tasks/-Models/-Reps/-Yes` make the whole thing
  non-interactive. Seats the live opencode config doesn't know are dropped
  before they can become `_INFRA_` runs. Also fixes the seat picker from #36,
  which offered every seat as one joined option: `return ,@(...)` wrapped in
  `@()` nests the array.
- `tests/test-toolcalls.ps1`: log every result to
  `tests/results/toolcalls-summary.tsv` with host label and Ollama version.
  Results were previously recorded by hand, and a probe only holds for the
  version it ran on. Accepts a `/v1` base URL. Fixes the usage comment's
  nonexistent `-Host` flag.
- Serve and register every desktop tool-capable seat at 32768 context:
  `qwen3.5:9b`, `qwen3-coder:30b-a3b` and `devstral:24b` were 16384. At 16k,
  OpenCode's ~14.4k-token standing preamble plus the 4096 output reserve does
  not fit, so those seats lost their system prompt before seeing a task. Baked
  by `startup.ps1` (`$contextModels`), with `limit.context` to match.
- Register the 2026-09-22 executor candidates in `opencode.jsonc` and
  `models/catalog.tsv`: on the desktop, `devstral-small-2:24b`,
  `north-mini-code-1.0`, `laguna-xs-2.1`, `qwen3.6:35b-a3b-coding` and
  `nemotron-3.5-lightning`; on node3, `ornith:9b`, `ministral-3:8b` and
  `lfm2.5:8b`. They are registered ahead of the probe with `tool_call: true`
  so one `-Mode Both` run can batch whichever pass. The script drops non-PASS
  seats, and a FAIL gets flipped to false afterwards.
- Desktop Ollama 0.34.1 → 0.34.3 (manual install; the `pin-ollama-desktop.ps1`
  firewall rule stays, so the tray app still cannot self-update). Desktop
  models moved from `C:\Users\<you>\.ollama\models` to `M:\ollama\models`
  (User-level `OLLAMA_MODELS`).
- Add `docs/target-setup.md`: the planned fleet end state once the server is
  back, derived from the owner's stated workflow (interactive planning only;
  unattended, slow implementation is fine; TypeScript first; offload to local
  rather than replace Claude Code/Codex). A strong model writes work orders
  with the acceptance test already in them. The fleet runs N attempts across
  hosts, and the existing task-harness gates pick the winner. Includes machine
  roles and ordered milestones.
- Record the 2026-09-22 edit-reliability analysis in
  `docs/implementation-tasks.md`: `edit` succeeds 11% of the time across all
  graded transcripts. 79% of misses target code that isn't in the file (not
  whitespace), 94% of reads are small slices, and 30% of edits hit unread
  files. Close the node3 "flapping" follow-up: the cause was Windows sleep.
- `docs/hardware.md`: desktop RAM (32 GB), free-RAM-for-spill notes, the
  2026-09-22 Ollama library scan of candidate executor models per host, and
  ranked hardware upgrade candidates for AI. Adds wired LAN and per-option
  disk totals (~102 GB for all large candidates, ~17 GB for node3's; the
  desktop's current install measures 85.8 GB).
- Make `tests/run-tasks-batch.ps1`'s task and model pickers data-driven. The hardcoded
  seat list is gone: options now come from `tests/run-tasks-models.tsv` (a row
  per tag the toolcalls probe measured PASS on, with eligible hosts)
  intersected against each live host's `/api/tags`, so a new tool-capable model
  is one TSV row and a down host or an unpulled tag stops being offered on its
  own. The newly imported `qwen3.5:9b` and `qwen3-coder:30b-a3b` seats appear
  via that mechanism (`deepseek-r1-0528:8b` stays custom-option-only — the
  probe measured it FAIL). Bench-branch pins moved into the tasks manifest
  (`branch` + `benchBaseCommit` per task) so `-SetupOnly` and the task picker
  are manifest-driven too.
- Set node3's `qwen3:8b` `limit.context` to `32768` in `opencode/global/opencode.jsonc`,
  this time backed by a measurement: `/api/ps` on a healthy node3 reports
  `context_length 32768` and `7.84 GiB` VRAM (Ollama 0.34.2) with the model
  loaded. The same number was set and reverted earlier on an unmeasured
  justification ("6/6 liar mode" that turned out to be six unreachable-host
  transcripts) — this entry replaces that guess with a reading.
- Fix `tests/test-tasks.ps1` silently stranding INFRA/TIMEOUT transcripts in
  `%TEMP%`. The cross-volume move (`C:\Temp` → `M:\results`) failed when a
  handle briefly held the file (opencode teardown / AV scan); the old
  `Move-Item -ErrorAction SilentlyContinue` swallowed the failure and still
  printed "kept," which is how 15 transcripts on 2026-09-21 and 12 more on
  2026-09-22 were left behind uncollected. A new `Move-Transcript` helper
  retries with backoff, falls back to copy+delete, and prints a truthful WARN
  with the stranded path when a source is genuinely stuck.
- Bring `AGENTS.md`'s task-veracity harness description up to date with the
  2026-09-21 fixes. It still described grading as "scope / suite / failsOnOld /
  typecheck" with no mention that a run is graded **only** if `opencode run`
  exited 0, that any non-zero exit is infrastructure and writes no
  `tasks-summary.tsv` row, that `run-tasks-batch.ps1` now refuses to start
  against a host that is not answering, or that `typecheck` can be `SKIP`.
  `AGENTS.md` is the first file an agent reads, so a stale harness contract
  there is the one most likely to be acted on.
- Withdraw a stale citation in `docs/roadmap.md`'s breadth-vs-depth rationale.
  It offered node3's `qwen3:8b` "liar mode" on `kane-01`/`lfc-01` as a second
  worked example of between-task variance; those runs never reached Ollama, so
  they are not evidence of anything about that seat. The `qwen3:14b` example
  still stands and the N=10 conclusion does not depend on the withdrawn one.
- Record the worktree-keying trade-off as an open follow-up in
  `docs/implementation-tasks.md`: `test-tasks.ps1` keys both the worktree and
  the install marker by task id alone, which is what makes same-task
  concurrency unsafe. Keying by task id **and** model label would delete that
  rule rather than document it, at the cost of one worktree and one
  `node_modules` per (task, seat) pair.

- Fix `tests/test-tasks.ps1` recording `typecheck: PASS` for tasks that never
  ran `tsc`. The flag was a boolean initialised to `$true` *before* the
  `if ($tk.typecheck)` guard, so the 6 of 8 manifest tasks with no `typecheck`
  block recorded a clean compile having compiled nothing - most starkly the
  three `kane-02` rows, which never reached the model at all. It is now
  tri-state: `PASS`/`WARN` only when the task defines the block, `SKIP`
  otherwise (a status the console summary already counted but never emitted).
  Only `kane-01` and `lfc-01` define one, so the other six now read `SKIP` -
  including all five never-run tasks, which would otherwise have added ~30
  vacuous `PASS` values to the next breadth batch. Rows written before this
  change still carry the old vacuous `PASS`; `tests/results/README.md` says
  how to read them.
- Correct the node3 concurrency plan in `docs/roadmap.md` (step 9 under
  "Put it to work on the task-veracity benchmark", and the pointer in item 3).
  It said desktop and node3 should run the same tasks "at the same time";
  `tests/test-tasks.ps1` keys the worktree by task id alone
  (`$wtPath = Join-Path $wtRoot $tk.id`), as it does the install marker, so two
  concurrent runs of one task id share a worktree and corrupt each other -
  the constraint AGENTS.md already states as "different task IDs only, never
  the same one twice". Split the terminals by disjoint task id instead, each
  running both seats; the wall-clock saving is identical.
- Add a desktop handoff to `docs/implementation-tasks.md`: the outstanding
  on-hardware verification for the harness and config changes, the ordered
  node3 bring-back sequence (measure `/api/show` before setting
  `limit.context` again), the dry-run preflight for the five never-run tasks
  with the `@asohav/shared` setup-step warning, and the N=3-then-N=10 breadth
  batch plan.

- Fix `tests/test-tasks.ps1` grading infrastructure failures as model
  behaviour. It bailed out only on its `-1` timeout sentinel, so any other
  non-zero `opencode run` exit fell through to the writes gate and was
  stamped "0 write/edit calls - the model described the change instead of
  making it (the old liar mode)". opencode exits 0 even when a model
  answers in prose, so a non-zero exit is always infrastructure - an
  unreachable provider, a bad model id, a crash - and now produces a
  `FAIL`ed run, an `_INFRA_`-tagged transcript and **no summary row**,
  because a run that never reached the model measured nothing. The console
  now also quotes the transcript's first error event, so an unreachable
  host reads as "Cannot connect to API" instead of "exit 1".
- Add an endpoint preflight to `tests/run-tasks-batch.ps1`: every host the
  batch is about to drive is checked with `/api/tags` before the first run,
  and the batch refuses to start against one that is not answering. Covers
  `$env:OPENCODE_SMALL_MODEL`'s host too, which matters because
  `profiles/dev-node3.sh` points the small model at `ollama-server` - down
  since 2026-09-16.
- Correct the record on node3's `qwen3:8b` "liar mode", and **revert** the
  `limit.context` 16384 -> 32768 bump in `opencode/global/opencode.jsonc`
  that was made on the strength of it. All six node3 task-veracity
  transcripts are 307 bytes holding exactly one event: an `APIError`,
  "Cannot connect to API", against `http://NODE3_IP:11434/v1/chat/completions`.
  No request ever reached Ollama, so those runs are not evidence about
  context budget, tool-calling or this model in any direction - and the
  `kane-02` subset is not the stale `setup` step either, since the same
  signature appears on `kane-01` and `lfc-01`, which never had that step.
  Node3's liar-mode denominator is **0, not 6**; it has no capability data
  yet. The preamble arithmetic remains unresolved (~12,288 tokens of input
  budget at 16384 vs a measured 14,364-token preamble), so measure what
  node3 actually serves before setting this number again - see
  `docs/roadmap.md`'s corrected entry for the order to do it in.
- Raise `ollama-desktop`'s `qwen3:14b` `limit.output` from 4096 to 8192.
  At 4096 the seat exhausted its output budget inside its own reasoning
  block on 8 of 16 task-veracity runs (`step_finish` reason `"length"`,
  usage output exactly 4096, ~25k of the context window still unused), and
  on `kane-01` it hit the cap before any edit call on 7 of 9 runs - leaving
  the seat with almost no gradable data and invalidating every 14b-vs-8b
  comparison drawn from it. 8192 is the reasoner budget that file's own
  rules already prescribe; the prompt window stays at 24,576.
- Add `.claude/hooks/session-start.sh` (`SessionStart` hook, registered in
  `.claude/settings.json`): installs `pwsh` in remote/Claude-Code-web
  sessions, gated on `$CLAUDE_CODE_REMOTE` so it never touches a local
  session that already has real Windows PowerShell. Idempotent (no-ops if
  `pwsh` is already on `PATH`). Prompted by the `kane-02` bug below - AGENTS.md's
  own `ParseFile` syntax-check convention had no PowerShell to actually run
  against in a remote session, only a bracket-balance approximation.
  Installs the official Linux binary tarball (x64/arm64) to
  `/opt/microsoft/powershell/7`, symlinked to `/usr/local/bin/pwsh`. Verified:
  ran the hook directly (`CLAUDE_CODE_REMOTE=true .claude/hooks/session-start.sh`)
  from a clean state, confirmed `pwsh --version` afterward and confirmed
  `tests/run-tasks-batch.ps1` and `tests/test-tasks.ps1` both parse clean.
- Fix `kane-02-multiword-creature-type`'s manifest entry: it shipped with a
  `setup` step (build `@mtg/rules`) copied from `kane-01`'s entry without
  re-checking it against `kane-02`'s own pinned commit - `packages/rules`
  doesn't exist yet at that point in KaneEnabler's history (`git ls-tree`
  confirms only `packages/config` does), and `signals.ts` has no `@mtg/rules`
  import there at all. The original verification pass missed this because it
  built `@mtg/rules` while still on `main` (current HEAD) *before* creating
  the task's bench branch - the stale `packages/rules/dist/` build output
  was untracked and survived the branch switch, so the sandbox test passed
  even though a real `git worktree add` (no such leftover) cannot resolve
  it. Surfaced 2026-09-21 while investigating three node3 runs of this task
  that failed identically - those runs turned out to have died at the
  `opencode run` API call (node3 unreachable), not here, since a failed
  setup step returns before any summary row is appended and all three
  appended one. Reading them is what exposed this. Removed the `setup` block; re-verified in a genuinely
  fresh worktree (28/28, no setup needed) and re-audited every other new
  task's import requirements directly against git history (`git show
  <commit>:<path>` - no working-tree checkout, so immune to the same
  mistake) - `kane-03`/`kane-04`/`lfc-02` correctly have no setup step,
  `asohav-01`/`asohav-02` correctly do.
- Add `tests/run-tasks-batch.ps1`: wraps `test-tasks.ps1` for day-to-day use.
  Ensures every task's local `bench/*` branch exists (idempotent, reads repo
  paths from the manifest, commit hashes match `docs/roadmap.md`'s task-set-
  expansion table), then interactively prompts for which task(s), which
  model(s), and how many repeats of each, and runs one `test-tasks.ps1`
  invocation per (task, model, rep) combination. `-SetupOnly`/`-SkipSetup`
  split the two phases. Sequential by design, not parallel — the worktree-
  keyed-by-task-id constraint means true concurrency still needs two
  separate terminals running non-overlapping task IDs directly.
- Task-veracity benchmark: strategy pivot from depth to breadth, since the
  actual goal is general capability, not just `kane-01`/`lfc-01`. Cap N at
  **10 per model/task cell** (was heading toward 30-50), added GitHub read
  access + shallow clones for `mkane848/kaneenabler`, `asohavcompanionapp`
  and `lfc-bot`, mined each repo's commit history for real merged bug-fix
  commits, and added **6 new tasks** to `tests/tasks/manifest.json` —
  `kane-02-multiword-creature-type`, `kane-03-saga-chapter-triggers`,
  `kane-04-singleton-up-to-n`, `asohav-01-library-write-reporting`,
  `asohav-02-changelog-uuid-id`, `lfc-02-scryfall-headers` — bringing the
  set to 8, with 16 as the target. Every task independently verified
  (baseline green at the parent commit, `failsOnOld` confirmed red) before
  being added; two candidates found and dropped for not isolating cleanly
  to a 2-file scope. Full reasoning, the verification table, the dropped
  candidates, and the `MANAPOOL_API_KEY` caveat on `lfc-02` in
  `docs/roadmap.md` ("Task-veracity benchmark: task set expansion"). Each
  new task's pre-fix state lives on a new local branch (`bench/*`) that
  must be created in the corresponding local checkout before it can run —
  commands in the same roadmap section.
- Harden `tests/test-tasks.ps1`'s prompt-hash line: it called
  `[Security.Cryptography.SHA256]::HashData(...)` and `[Convert]::ToHexString(...)`,
  both .NET 5+ convenience APIs. Hit a `does not contain a method named 'HashData'`
  failure on desktop (2026-09-21) on the first invocation of a shell session; an
  identical retry succeeded, so the root cause looks like a transient type-resolution
  race rather than a real PS 5.1/PS 7 split — but the script already targets both
  runtimes (AGENTS.md), so swapped to `SHA256.Create()` + `ComputeHash()` +
  `BitConverter.ToString()`, which needs nothing newer than .NET Framework and
  produces the identical uppercase 12-char hex prefix.
- Task-veracity benchmark: 4 more graded runs (2026-09-20 evening, Ollama
  0.34.1, opencode 1.18.31; base `92a8ed0` for `kane-01-background-pair`,
  `4906dc2` for `lfc-01-listing-status-guard`).
  `kane-01-background-pair` on `ollama-node3/qwen3:8b` x2 (21:55, 22:05) —
  both exit 1 with 0 writes, scope FAIL / suite PASS / failsOnOld FAIL.
  `lfc-01-listing-status-guard` on `ollama-desktop/qwen3:14b` x2 — 21:58
  fully landed (2 writes, all four gates PASS), 22:12 scope PASS / suite
  FAIL / failsOnOld PASS (6 writes). Rows appended to
  `tests/results/tasks-summary.tsv`; raw `.json`/`.jsonl` transcripts
  committed verbatim, ungraded per CONTRIBUTING.
- Disable the `~/.claude` skill rider: opencode auto-loaded the Claude Code
  plugin's synced skills (`~/.claude/skills/synced/`, 10 SKILL.md, 167 KB) into
  every request behind `$GLOBAL_SKILL_SOURCES`'s back. Measured on the desktop
  (2026-09-20): OK probe `task.n_tokens` 16,851 → 14,364 and prompt prefill
  113 s → 84 s with `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1`. Baked into all
  four live profiles + forwarded by `desktop/scripts/opencode.ps1` + set as a
  User-level env default; `AGENTS.md` Preamble Budget gotcha expanded with the
  measurement and the keep-it-set warning.
- Document the `gh pr create/edit --body` PowerShell trap in `AGENTS.md`
  (Gotchas) and `CONTRIBUTING.md`: inline `--body "..."` eats backticks, so
  write the body to a file, pass `--body-file`, and re-read the rendered body
  with `gh pr view`. Learned the hard way on PR #19/#20, whose bodies had to
  be re-saved after merge.
- Documentation cleanup after the node3 onboarding: every live/parked
  profile count now says 4 / 8 (was 3 / 9 across `README.md`,
  `docs/profiles.md`, `profiles/README.md`); `dev-node3.sh`'s `FUTURE/STUB`
  header, `profiles/parked/README.md`'s "never provisioned" section, and
  `docs/network-topology.md`'s `(future)` labels updated for the live node;
  ROCm remnants corrected to Vulkan (`desktop/README.md` rewritten sections,
  `dev.dockerfile`, `docker-compose.yml`, `sandbox.md`, `troubleshooting.md`,
  `models.ps1`, `config.example.json` — whose stale `OLLAMA_CONTEXT_LENGTH`
  note now describes the per-model bake); `opencode/README.md` counts fixed
  (73 skills with vercel at 44, 4 agents, no `planner.md`) and its provider
  table corrected (no GLM4 on desktop, full desktop seat list);
  `docs/start-here.md` + `CONTRIBUTING.md` expect the measured **100 PASS /
  0 FAIL / 1 WARN / 2 SKIP**, closing the roadmap's pass-count contradiction;
  `dev-workflow-resident.sh`'s VRAM header re-based to the served 32k figures
  (11.97 GB) with its removed-subagent echo fixed; server-block `tool_call`
  comment records the measured node3 `glm4:9b` FAIL. Verified with
  `test-profiles.ps1` (full: 100/0/1/2) and `-Profile dev-node3` (15/0/1/2).
- Refresh `AGENTS.md` for the node3 onboarding and other drift: 4 live
  profiles / 8 parked (was 3 / 9), `origin` remote documented (was "no
  remote configured"), node3 marked onboarded with `qwen3:8b` as the only
  agent seat, desktop context-bake list corrected against `startup.ps1`
  `$contextModels`, catalog↔`opencode.jsonc` gap note rewritten (per-host
  registration + the three LM-Studio imports with no catalog row), and new
  pointers to the `-Reliability` canary, the `test-tasks.ps1` benchmark, and
  the PR/changelog convention. Commits the staged `dev-node3.sh` unpark
  alongside so the live-profile count holds in-tree.
- Third node (RTX 3080 FE) onboarding complete 2026-09-20: `dev-node3.sh`
  unparked, `test-profiles.ps1 -Profile dev-node3` green (15 PASS, 0 FAIL,
  1 WARN, 2 SKIP). The WARN (`install intent (node3) -> missing on host:
  qwen3:14b, gpt-oss:20b`) is a documented false positive — the harness's
  group-expansion for `DEV_NODE3_MODELS` doesn't check the catalog's
  `hosts` column, and neither model was ever intended for this host
  (`gpt-oss:20b` is `hosts=server,desktop` only; `qwen3:14b` isn't
  registered in node3's `opencode.jsonc` block because 14B weights are
  tight on a 10 GB card). Do not install either to silence it. The 2 SKIPs
  are the pre-existing, unrelated Ubuntu server outage. `docs/hardware.md`'s
  `(future)` tag on the third-node row is removed accordingly, and the
  roadmap's north-star progression note updated to record that node3 came
  online ahead of the server (stage 2), inverting the plan's original
  ordering.

- Third node (RTX 3080 FE) onboarding, steps 1-6 done 2026-09-20: Ollama
  installed, LAN bind + firewall confirmed (`0.0.0.0:11434` listening),
  `qwen3:8b`/`glm4:9b`/`nomic-embed-text`/`mxbai-embed-large` pulled,
  `NODE3_IP` reachable from the desktop. Real tool-calling probes run for the
  first time on this host: `qwen3:8b` **PASS** (62.3s, real `write_file`
  call), `glm4:9b` **FAIL** (32.8s, ignored the tool and answered in prose).
  The `glm4:9b` result closes a real gap flagged in the previous entry —
  `opencode/global/opencode.jsonc`'s `ollama-node3` block claimed
  `"tool_call": true` for it with no measurement behind that claim; corrected
  to `false` now that one exists, and it's recorded in AGENTS.md's Gotchas
  alongside the other measured failures. `qwen3:8b` stays the only node3
  agent seat, unchanged from `dev-node3.sh`'s existing default. Also fills in
  `docs/hardware.md`'s previously-unknown node3 RAM figure (32 GB).
- Task-veracity benchmark: 15 more harness runs to bulk up the graded sample
  on the qwen3 seats for both tasks (base `92a8ed0` for
  `kane-01-background-pair`, `4906dc2` for `lfc-01-listing-status-guard`).
  11 new graded rows appended to `tests/results/tasks-summary.tsv`; 4 runs hit
  the harness's 900 s `opencode run` cap and append no row (existing timeout
  design). Results — Task 1, qwen3:14b x4: 0/4 landed (two zero-write
  liar-mode runs, one 1-write run that broke the suite with a re-parse error,
  one 7-write run whose suite failed a legality assertion; the test file went
  unmodified every run, so failsOnOld stayed red). Task 1, qwen3:8b x3:
  0/3 landed (the 30- and 2-write runs edited only `deckValidation.ts` and
  left the test file untouched so the claimed branch is never exercised; the
  35-write run left the suite green but still never touched the test, so
  failsOnOld stayed red). Task 2, qwen3:14b x2: 0/2 landed (both runs the
  same shape — 3 writes, both claimed files in scope, but `listings.test.ts`
  left with a `'} expected'` parse error, suite load/parse FAIL, typecheck
  WARN). Task 2, qwen3:8b x2: 0/2 landed (9- and 30-write runs edited only
  `listings.ts`, leaving the guard test unwritten; suite FAIL, failsOnOld
  FAIL). Cumulative: still 0 successful fixes across both tasks — the
  "test never enters its claimed branch" class now dominates the failures,
  consistent with the existing read of an under-powered sample rather than a
  hard ceiling.
- Plan the third-node (RTX 3080 FE) onboarding now that the hardware exists:
  expand `docs/roadmap.md`'s onboarding checklist into a concrete join →
  probe → put-to-work sequence (CUDA, not Vulkan — no flash-attention
  workaround needed), flag that `glm4:9b`'s `"tool_call": true` entry in
  `opencode/global/opencode.jsonc` doesn't appear in the actual measured
  tool-calling pass/fail list and needs a real probe before it holds an
  agent seat, and note the concrete payoff for the task-veracity benchmark
  (real parallel trial capacity, not just another row in a table). Also
  records Unsloth's installation on that machine as a separate, explicitly
  gated future track (fine-tuning) — gated on there being a genuine
  successful trajectory to train on, which the benchmark doesn't have yet.
  No config or seat changes made; nothing here is live until the node is
  actually onboarded.
- Task-veracity benchmark: external research pass on the combined Task 1 +
  Task 2 result (0/7 graded runs). Confirms the harness's 4-gate design
  (scope/suite/failsOnOld/typecheck) matches SWE-bench's own methodology,
  and that Task 1/2 sidestep a documented SWE-bench contamination critique
  by using private, unpublished bugs. Names the qwen3:14b "liar mode" and
  devstral destructive-rewrite failures as a studied class (reward hacking /
  MIRAGE-Bench's agent-hallucination taxonomy), not one-off flukes.
  **Correction:** published base rates for the *un-tuned* models this fleet
  seats (plain Qwen3-8B ≈ 8% on SWE-bench Verified; Devstral-Small ≈ 17.2%
  pass@1 on SWE-MERA) put 0 successes in 7 trials at roughly 20–55%
  probability by chance alone — so "0/7" should be read as an
  under-powered sample, not confirmed evidence of a hard capability
  ceiling. Adds an unscheduled testing-plan item (hosted/frontier-model
  calibration arm on the existing Task 1/2 prompts) and reorders "Next up"
  to prioritize more repeat trials over a 3rd task shape. See
  `docs/roadmap.md` → "Task-veracity benchmark: external research pass".
- Run Task 2 of the task-veracity benchmark (`lfc-01-listing-status-guard`)
  across all three seats on the real `opencode run` tool loop (base `4906dc2`,
  baseline green 21/21 every run): **0 of 3 landed the fix**, each failing
  structurally and differently. qwen3:14b in liar mode — both `edit` calls
  errored (multi-match `oldString` for `setStatus`'s shared `where(eq(id,id))`;
  guessed literal test anchor), then it ran vitest, saw the untouched green
  suite, and *asserted in prose* that the fix and new tests were done; its first
  run (900 s timeout) was the same loop before the rerun failed fast (167 s).
  qwen3:8b by breaking the build — deleted `const db = getDb();` and wrote
  module-level `await db.select(...)/db.update(...)` into the sync `setStatus`
  (TS2304/TS1308/TS7006), so the file never parses and the suite runs 0 tests.
  devstral:24b by a destructive full-file rewrite hidden behind two harness
  timeouts — at +12 min it replaced the 516-line `listings.test.ts` with 4
  mangled comment lines (`<%/* */%>`), then produced nothing flushed for 7.5 h;
  the `tool_use` events were lost to the force-kill's buffer flush, which is why
  its post-kill transcript shows only a `step_start`. Fix the harness on the way
  (branch `task2`, PR #13): the `setup`-array crash for tasks without a `setup`
  array, and the `Get-FailedTestNames` blind spot that printed an **empty** FAIL
  for broken modules (`Failed Suites N` / `Tests no tests` vs. `Tests N failed` —
  now captured, gated on `Failed Suites N`, with the failing file named).
  Write-up in `docs/roadmap.md` → "Task 2 first graded runs"; evidence
  (per-run `.json` + `.jsonl` transcripts, preserved STALL transcript, destroyed
  test file) in `tests/results/`. No seat/config change made, per the benchmark
  gate (≥3 graded runs across ≥2 tasks satisfied by *something*).
- Add Task 2 to the task-veracity benchmark manifest:
  `lfc-01-listing-status-guard` (lfc-bot), a missing-validation bug —
  `setStatus()` in `src/services/listings.ts` updates a listing's status by
  `id` alone with no guard on its current status, so an already
  fulfilled/deleted/expired listing can be re-fulfilled or re-deleted,
  silently resurrecting it. Deliberately a different bug shape from Task 1's
  eligibility/conditional-logic bug. Found by codebase survey, independently
  verified against the actual source, all three call sites, and existing
  test coverage before being written into the manifest — never taking a
  survey's word for it, same discipline as the rest of this repo's research.
  Fixes the harness to get there: `Ensure-Worktree`'s install step was
  hardcoded to `pnpm install`, which would silently mis-install an
  npm-only repo (no pnpm lockfile); it's now `packageManager`-aware per task
  (defaults to `pnpm`, so kane-01 is unaffected). The task's scoped
  typecheck extends `tsconfig.eslint.json`, not `tsconfig.json` — confirmed
  empirically (`tsc --noEmit --listFiles`) that the latter's inherited
  `exclude: [..., "tests"]` silently drops the test file from an explicit
  `include` even when named directly, which would have made the typecheck
  gate a no-op on exactly the file it needs to check.
- Add the task-veracity benchmark harness (`tests/test-tasks.ps1`) and task
  manifest, seeded with the background-pairing task and its first graded runs
  (qwen3:14b, qwen3:8b x2, devstral:24b — all FAIL on the six mechanical gates).
- Harden the task-veracity benchmark harness before Task 2: raw run
  transcripts are now kept (moved into `tests/results/*.jsonl`, paired by
  filename with the graded JSON) instead of deleted from `%TEMP%` — the same
  round-2 mistake this repo's review-gate work already learned from. Every
  run also records `ollamaVersion`/`opencodeVersion`. Sampling (seed/
  temperature) is explicitly documented as NOT controlled or recorded —
  `opencode run` has no known per-invocation flag for either, unlike
  `docs/review-gate/r3-runner.ps1`'s direct-Ollama-API approach — rather than
  fabricate a reading for a parameter this harness cannot currently pin.
- Cross-check the `devstral:24b` zero-write result from the task-veracity
  benchmark (`kane-01-background-pair`) through VS Code Agent mode, same base
  commit and identical prompt: reproduced - 0 files changed. Confirms the
  failure isn't an OpenCode/raw-Ollama-template artifact.
  (`tests/results/tasks-kane-01-background-pair-devstral-24b-vscode_*.json`)
- Add `CONTRIBUTING.md` and a GitHub pull-request template codifying the repo's
  review-gate verification standard and changelog convention.
- Plan the fleet decision on the review-gate results: third 16 GB node vs.
  partial-offload R1 on node3 vs. `glm4:9b` (see `docs/roadmap.md`).

## [0.1.0] - 2026-09-19

Initial versioned snapshot of the repository. Everything merged as of this
date; no release tags have been cut yet.

### Added

- Hybrid Ubuntu-server / Windows-desktop local-LLM fleet documentation, as a
  public home-lab write-up: hardware notes, per-model VRAM/tool-calling
  benchmarks, and a live BIOS-recovery log.
- Model catalog (`models/catalog.tsv` as single source of truth +
  `models/catalog.sh` bash library), per-host Ollama provider config split one
  per host in `opencode/global/opencode.jsonc`, and server/desktop install and
  sync scripts.
- Per-machine tier profiles and model intent (`profiles/dev-*.sh`), an
  interactive picker, and a startup pipeline that bakes a per-model `num_ctx`
  into managed tags.
- The review-gate research thread: auditor and reviewer role prompts,
  deterministic seam-checker robot, round-1 and round-2 case studies
  (including the PR #82 merge-review findings), the round-2 re-measure and its
  corrections, and the round-3 two-arm experiment (ledger clause vs. control;
  18 raw runs committed with a full manifest).
- Robot negative-control protocol and fixtures proving `seam-checker.ps1`
  discriminates: baseline reproduces RED-MARK, the covered fixture goes
  FIRST-RUN-SAFE, the reflowed fixture stays RED-MARK.
- Tool-calling probe `tests/test-toolcalls.ps1` and the re-measured results on
  Ollama 0.34.1 (5 of 13 models pass).
- A `-Reliability` write-discipline gate in the profile test harness.

### Changed

- Repo placed under git (2026-09-17) and switched to feature-branch pulls.
- README rewritten for public sharing; repo moved under an MIT license with
  docs reorganized.
- VS Code surfaced as a first-class interface alongside OpenCode, with an
  LM Studio / BYOK workflow documented.
- `/plan` prompt shortened; the orphaned planner agent removed.
- Desktop Ollama version pinned via a new pin script, then both desktop and
  server re-pinned to Ollama 0.34.1 after the auto-update (see Fixed).
- `dev-wife.sh` renamed to `dev-node3.sh`; stale wording generalized.
- Server profiles parked; the profile picker made dynamic.

### Fixed

- `/plan` issued a prompt too long for the 16k seat; shortened so it works.
- Round-2 comparison corrected: draw 2 was CAUTION with both deciding seams
  flagged (previously mis-recorded).
- Two tool-call count references missed by the first 0.34.1 re-baseline.
- `OLLAMA_CONTEXT_LENGTH` behaviour on Windows corrected in docs; the
  per-model bake approach remains.

[unreleased]: https://github.com/mkane848/HomeLab/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mkane848/HomeLab/releases/tag/v0.1.0