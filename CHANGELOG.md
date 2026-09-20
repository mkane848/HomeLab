# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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