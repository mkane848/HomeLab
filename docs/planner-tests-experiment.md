# Experiment 3: planner-written acceptance tests (design 2026-10-24, first run 2026-10-31)

Milestone 3 gave the executor its acceptance tests, and milestone 4's dispatcher (`tests/run-retries.ps1`) keeps the
first attempt that passes them. In both, the tests shown were the tasks' own hidden tests, written to grade a
known-good fix, so "the given test passes" was a perfect selector by construction
([adversarial-review-2026-10-23.md](adversarial-review-2026-10-23.md), finding 4; the 2026-09-29 review's planner item).
Real use has no such tests: the planner writes them before the work. This experiment measures what that costs.

First run 2026-10-31/11-01, at the design's size as a screen: see "Results (first run)" at the end.

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
- **How it runs (2026-10-31):** in a container, not a cloud session. `desktop/scripts/make-planner-packs.py` builds one
  pack per task (the request and a git bundle of the base commit and its history, nothing later);
  `desktop/scripts/run-planner.ps1` runs Claude Code on it inside `desktop/docker/planner/`, on an internal network
  whose only exit is a proxy that allows `api.anthropic.com` and `registry.npmjs.org`. The task repos are public, so
  the fix is one `git clone` away for any planner with open internet; the proxy removes that, and the web tools are
  switched off because WebSearch runs on Anthropic's side. CPU only.
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

- ~~**No planner has been run.**~~ Run 2026-10-31: "Results (first run)" below.
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

## Results (first run, 2026-10-31 to 11-01)

A screen at the design's size (owner, 2026-10-31: power-sizing would have needed roughly twice the planner-arm runs).
Private results: `tasks/planner/` (the sets, notes and planner sessions), `results/planner-validate/`,
`results/exp3-planner`, `results/exp3-oracle`, `results/exp3-hidden`.

**Setup.**
- **Planner:** Claude Code 2.1.316 with Opus 5.5 (`claude-opus-5-5`), prompt version 2 (`tasks/planner/PROMPT.md`,
  sha256 `9611edcf71fa`). It ran in the container (`desktop/docker/planner/`: allowlist proxy, web tools off), one
  fresh container per task and run, 6 tasks × 2 runs. 12 sets, about $8 of usage, 3 to 7 minutes each; `wp-6f` run 2
  needed a second session (the first stopped after 112 s with no files).
- **Executor:** `qwen3.6:35b-a3b-coding` on the server's llama.cpp (b11561), tools on the desktop (opencode 1.19.5,
  harness `d201fb7`), sealed checkouts, nudged, classifier 3, shown prompt 2, 2,700 s a run. The arms rotated per task
  and rep. 71 of 72 runs graded; one `wp-5b` planner run ended context-exceeded.
- **Tasks:** `real-01`, `real-02`, `real-03`, `wp-1a`, `wp-5b`, `wp-6f`.

**Validation of the sets** (dry runs: fails on the base, passes on `acceptance.solution`): **8 of 12 valid.** The 4
invalid sets are both of `real-02` (they require `AGENTS.md` content the real fix does not add: CI's npm audit gate,
every `src/` directory, no unused environment variables) and both of `wp-5b` (written independently, both expect a 400
for a non-string tag or Improvement, which the real fix does not return). Every set failed on the base. LFCbot's
`npm ci` could not build `better-sqlite3` in the container (Node headers from `nodejs.org`, refused by the proxy then,
allowed since #178); the planners used `--ignore-scripts`, and all three LFCbot tasks only read files.

**The selector** (the planner's tests) against the truth (the hidden tests), 35 planner-arm runs:

| Measure | Count | Rate (95% Wilson interval) |
|---|---|---|
| false positives: selector PASS, hidden FAIL | 3 of 28 | 11% (4% to 27%) |
| false negatives: selector FAIL, hidden PASS | 0 of 7 | 0% (0% to 35%) |
| kept by a dispatcher (selector, scope, suite PASS, nothing tampered) but wrong | 3 of 28 | 11% (4% to 27%) |

- **All three false positives are `real-02`** ("make sure @AGENTS.md is up to date and clean"), 3 of its 6 planner
  runs, from both sets. On the other five tasks the planner's verdict matched the hidden tests in all 29 of their runs.
- **Each one failed a single hidden check about completeness:** "documents at least four of the five newer modules"
  (twice) and "keeps every section it had". The planner's tests checked that what `AGENTS.md` says is true, not that it
  says enough. Run 1's planner saw the gap and did not test it ("AGENTS.md also leaves out the batch, cards, replies and
  manapool utilities, but no test checks for them").

**What the shown tests did to the executor** (hidden-test passes per arm):

| Shown to the model | Passed | pass^k over tasks |
|---|---|---|
| the task's own tests (oracle) | 17 of 18 (94%) | pass^3 0.83 |
| a planner's tests | 25 of 35 (71%) | pass^5 0.53 |
| nothing (hidden) | 13 of 18 (72%) | pass^3 0.67 |

- **A planner's tests gave no lift over showing nothing**, where the task's own tests gave a large one.
- `wp-5b` is where they did least: its two over-strict sets went with 0 of 5 hidden passes (hidden arm 0 of 3, oracle
  2 of 3). The planner's tests rejected all five, and the hidden tests agreed, so none was a false negative.

**Against the stopping rule.** The point estimate, 11%, is above the 10% line, so the rule as written says redesign
before milestone 5. The interval (4% to 27%) spans the line, so the screen does not show which side the true rate is
on. What it does show is where the risk sits: a vague documentation request, whose acceptance is about completeness,
and not the work packages, whose prompts name files and behaviour.

**Next, in order** (step 1 done at the desk; see "Completeness review" below):
1. A review step on the planner's tests for completeness ("what would a correct answer have to include that no test
   checks?"), the first of the design's redesign candidates. `real-02` is the case to try it on, and the planner's own
   notes already name the missing checks.
2. More vague real-use tasks. One task carries every false positive, so the next run needs several of its kind to say
   anything about the class.
3. A power-sized run once the selector changes, sized on the planner arm's accepted attempts (about 40 for 80% power
   to tell 10% from 25%).

## Completeness review (desk, 2026-11-01)

Next step 1, done from the first run's logs with no new runs. Private: `tasks/planner/REVIEW.md` (the draft prompt),
`tasks/planner/meta/rebuild_real02.py` and `meta/real-02-rebuilt/`.

**The three false positives are two different gaps, one per set:**

| Attempt | Set | What the set checked | What the attempt got wrong |
|---|---|---|---|
| 2026-10-31 20:56 | 1 | env vars, `npm audit`, health endpoint, alerting, audit log, customId helpers | rewrote the whole file and dropped the `## Project` heading (its text kept) |
| 2026-10-31 21:10 | 2 | env vars, `npm audit`, audit log, every `src/` directory | documented 3 of the 5 newer modules |
| 2026-11-01 01:57 | 2 | (as above) | documented 3 of the 5 newer modules |

- **Set 2 missed coverage:** nothing about the health server, alerts, custom IDs or batch operations, which the code
  at the base already had. It is the case "what would a complete answer have to include?" asks about.
- **Set 1 covered four of the five modules and still let one through:** no test checked that what the file already
  had survives. "Clean" does not license dropping a section. Nothing in the design's candidates named this; it is a
  second question for the review step, "what must a correct answer keep?"
- **Both sets were also too strict** (validation: they fail on the real fix, for CI's `npm audit` gate, every `src/`
  directory and no unused environment variables). So the planner was mis-aimed, not just lenient: strict about things
  the request does not ask for, loose about the ones it does. A review step that only adds tests would make the
  first worse. The draft asks three questions: **missing**, **must survive**, **too strict**.

**An offline bench for `real-02`.** Each attempt changed only `AGENTS.md`, and its run log holds every edit. Applying
them to the base rebuilds all twelve `real-02` attempts across the three arms (every edit applies), and a port of the
hidden checks agrees with the recorded verdict on 12 of 12. A reviewed set can be scored on those twelve (six hidden
PASS, six hidden FAIL, the three false positives among them) plus the base and the fix, in seconds, with no executor
runs. The prompt was written after seeing these failures, so passing that bench is necessary, not sufficient; the
test that counts is the next run's new vague tasks.

**Next, revised:**
1. Run the review prompt on both `real-02` sets (two planner sessions, about $1.50) and score them on the bench.
2. If both reject the three false positives and pass the fix, write three to five new vague real-use tasks (the
   owner's own wording, like `real-02`), with hidden tests, before any power-sized run.
3. Then the power-sized run with the review step in the planner arm (about 40 accepted attempts).
