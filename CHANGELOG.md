# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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