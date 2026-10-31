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

## Harness (built 2026-10-31)

All five pieces exist in `tests/`, each with a guard (`test-show-acceptance.ps1`, `test-retry-loop.ps1`,
`test-summarize-rounds.ps1`):

1. **`-AcceptanceDir <folder>`** on `test-tasks.ps1`, with `-ShowAcceptance`: the folder (absolute, or relative to the
   manifest's folder like `acceptance.dir`) is shown instead of the task's own tests, while the task's hidden tests
   still grade. Alone it is refused, except under `-DryRun`.
2. **`selector` beside `acceptance` in the run JSON.** `selector` is the shown set's verdict (`source: "planner"`);
   `acceptance` stays the hidden tests' verdict, the truth. `plannerSet` records the folder and the set's hash. With
   the task's own tests shown the selector is those tests (`source: "hidden"`); a hidden-test run has neither. A selector
   that does not pass is a WARN, never a harness failure.
3. **The set validator**, in `-DryRun -AcceptanceDir`: the set must fail on the untouched base and pass on the task's
   `acceptance.solution`. Each answer goes to `planner-sets.tsv` (`valid`, `invalid`, `unchecked` when no solution is
   named, `error`); an executor run uses the set as written, valid or not, because a dispatcher in real use can run
   neither check.
4. **The reconciled shown prompt** (`-ShownPrompt 2`, the default) was already in.
5. **`run-retries.ps1` decides on `selector`**, never on the hidden tests, and records both per attempt
   (`selectors`, `truths`, `falsePositive`, `falseNegatives` in `retry-summary.tsv`). `{task}` in a string
   `-HarnessArgs` value is the task being run, so one command can give every task its own set.

Planner-shown rows are their own arm (an `ACCEPTANCE-PLANNER` marker in the results folder; the folder rules are the
other shown modes'). `summarize-rounds.ps1` prints, per planner arm, the false positives (selector PASS, hidden tests
FAIL) and false negatives (selector FAIL, hidden tests PASS) with Wilson 95% intervals, and how many runs a dispatcher
would have kept that the hidden tests call wrong. The 10% false-positive rule decides milestone 5.

Running it, for one task with a set per task under `<manifest folder>/planner/<task>/`:

```
pwsh tests/test-tasks.ps1 -Task <id> -Model <m> -TaskManifest <manifest> -DryRun -AcceptanceDir planner/<id>   # validate the set
pwsh tests/run-retries.ps1 -Tasks <ids> -Model <m> -MaxAttempts 3 -TaskManifest <manifest> -ResultsDir <own folder> `
     -HarnessArgs @{ AcceptanceDir = "planner/{task}" }
pwsh tests/summarize-rounds.ps1 -ResultsDir <that folder>
```

### Open items (2026-10-31)

- **No planner has been run.** The harness is only the instrument. The selector's false-positive rate, which the 10%
  rule needs, is still unmeasured.
- ~~**The mutation controls were not re-run.**~~ **Re-run 2026-10-31 on `main` (desktop, PowerShell 7): 6 of 6
  mutants caught.** The first build's checks were lost with its container. The guards themselves passed first: 238
  checks across `test-retry-loop`, `test-run-window`, `test-show-acceptance` and `test-summarize-rounds`. Then each
  mutant broke one line and its guard failed:

  | Mutant | Guard | FAIL lines |
  |---|---|---|
  | `run-retries.ps1` decides on the hidden tests instead of the selector | `test-retry-loop` | 8 |
  | `run-retries.ps1` ignores a failing selector | `test-retry-loop` | 13 |
  | `test-tasks.ps1` grades the selector with the hidden tests, not the planner's set | `test-show-acceptance` | 4 |
  | `test-tasks.ps1` records no selector | `test-show-acceptance` | 5 |
  | a planner set counted valid when it passes on the base | `test-show-acceptance` | 1 |
  | `summarize-rounds.ps1` counts false positives as hidden PASS | `test-summarize-rounds` | 4 |
- **Guards on Linux:** `test-show-acceptance.ps1` has one failure as root on Linux (the read-only plain-write check),
  identical on `main` before this harness, and needs `TEMP=/tmp` set. The other 28 guards that fail on a Linux
  sandbox are the Windows-first ones and fail the same on `main`. CI (Windows, pwsh 7) is the authority.
