# Experiment 3: planner-written acceptance tests (design, 2026-10-24)

Milestone 3 gave the executor its acceptance tests, and milestone 4's dispatcher (`tests/run-retries.ps1`) keeps the
first attempt that passes them. In both, the tests shown were the tasks' own hidden tests, written to grade a
known-good fix, so "the given test passes" was a perfect selector by construction
([adversarial-review-2026-10-23.md](adversarial-review-2026-10-23.md), finding 4; the 2026-09-29 review's planner item).
Real use has no such tests: the planner writes them before the work. This experiment measures what that costs.

Not yet run. Nothing here is built; the harness changes it needs are listed at the end.

## The question

**How often does a planner's own test accept wrong code, and reject right code?** On the same tasks, with the hidden
tests as ground truth:

- **Selector false positives:** an attempt passes the planner's test but fails the hidden tests. This is the rate
  that ships wrong code unattended, so it decides milestone 5.
- **Selector false negatives:** an attempt fails the planner's test but passes the hidden tests. It costs retries,
  not correctness.
- **First-attempt pass rate** against the planner's test, which sets the retry cap and whether parallel attempts
  earn their place (`docs/roadmap.md` → "After the trial" item 6).

No catalogued source measures this for LLM-written acceptance tests (checked 2026-10-23, `docs/references.md`); a
literature search goes before the run.

## The planner

- **Who:** Claude Code, the owner's planning seat (`docs/target-setup.md`, "Plan with a strong model").
- **What it sees:** the task's prompt as the owner wrote it and the repository at the task's base, in a sealed
  checkout (nothing after the base is reachable). Never the hidden tests, the fix commit or any earlier run.
- **What it writes:** test files only, in the repository's own test layout, plus one line per file on what it
  checks. No source changes.
- **Its prompt:** fixed text, kept in the private task folder and hashed into each row, so planner runs are
  comparable. It asks for tests that fail on the current code and pass once the task is done, and nothing more.
- **Where its output goes:** `HomeLab-private/tasks/planner/<task>/<n>/`, one folder per planner run, outside every
  repo, like the hidden tests.

## Validating the planner's tests before any executor run

Each planner test set is checked mechanically against two fixed points, much as `-DryRun` checks hidden tests today:

1. **It must fail on the base.** A test that passes on unchanged code checks nothing (`failsOnOld`'s rule, inverted).
2. **It must pass on the known-good solution** (the task's `acceptance.solution` or `acceptance.commit`). A planner
   test that fails there is over-strict or wrong.

The pair gives a planner-quality score of its own (the share of sets valid on both points). Both outcomes are
reported. Executor runs use the planner's set as written, valid or not, because a dispatcher in real use cannot run
either check (it has no solution to check against).

## Executor runs

- **Mode:** `-ShowAcceptance` with the planner's set in place of the hidden folder, and the prompt line naming those
  files. The task prompt is the reconciled shown prompt from roadmap item 10's step 1, so the instruction conflict
  that produced milestone 3's tampering is not reintroduced.
- **Grading, both ways on every run:** the planner's tests (the selector the dispatcher sees) and the hidden tests
  (the truth), each from the harness's own copy, plus scope and the suite as today.
- **Arms, interleaved by rep:** planner-shown, oracle-shown (today's mode, the ceiling), hidden (the floor).
- **Host and settings:** qwen3.6 on the server's llama.cpp, tools on a free run host, sealed checkouts, classifier 3,
  the round scripts' settings at the time.

## Tasks and size

- **Tasks:** the capability set (`real-02`, `real-03`, `wp-5b`) plus 3 regression-set tasks of different kinds, so
  there is a mix of easy and hard. `real-*` prompts are the owner's own, short ones; the work-package prompts are long
  and specify files, which makes them easier to plan than real requests, as
  [Saving SWE-Bench](https://arxiv.org/html/2510.08996v2) found for benchmark prompts generally.
- **Planner runs:** 2 per task (planner variance is part of the answer).
- **Executor runs:** 3 per planner set per arm. That is 6 tasks × 2 sets × 3 reps = 36 planner-shown runs, plus 18
  each for the other two arms.

## Stopping rules and verdicts

- **False positives above 10%** of planner-passing attempts: redesign before milestone 5. Candidates: a review step
  on the planner's tests, mutation checks (does the test fail on deliberately broken variants of the solution), or a
  second planner.
- **False positives at or below 10%:** milestone 5 can rely on the planner's test plus the owner's review.
- **Every rate is reported with its counts.** At this size a rate is a range, and the 3-point skepticism rule of
  [Quantifying infrastructure noise](https://www.anthropic.com/engineering/infrastructure-noise) applies a
  fortiori.

## Harness changes it needs (none built yet)

1. A per-task or per-run override of the shown folder (an `-AcceptanceDir` beside `-ShowAcceptance`), so the
   planner's set is shown while the hidden folder still grades.
2. A second acceptance verdict in the run JSON: `selector` (the shown set's result) beside `acceptance` (the hidden
   tests'), and the planner set's id and hash.
3. The planner-set validator (base fails, solution passes), reusing `-DryRun`'s path.
4. The reconciled shown prompt (roadmap item 10, step 1).
5. `run-retries.ps1` reading `selector` instead of `acceptance` once it exists, so the dispatcher never sees the
   truth.

Each gets a guard, as usual.
