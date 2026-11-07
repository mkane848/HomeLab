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
1. ~~Run the review prompt on both `real-02` sets (two planner sessions, about $1.50) and score them on the bench.~~
   Done the same day: "Review step, version 1" below. It did not pass, so step 2 changed.
2. If both reject the three false positives and pass the fix, write three to five new vague real-use tasks (the
   owner's own wording, like `real-02`), with hidden tests, before any power-sized run.
3. Then the power-sized run with the review step in the planner arm (about 40 accepted attempts).

## Review step, version 1 (2026-11-01)

The draft review prompt (private `tasks/planner/REVIEW.md`, run as the pack's `PROMPT.md`, sha256 `0871269fad16`),
run once on each `real-02` set in the planner container (Opus 5.5, Claude Code 2.1.316, web tools off): 276 s and
229 s, $1.29 together. The sessions were started by `run-planner.ps1` unchanged, whose opening line still says "Plan
the acceptance tests"; both noticed and followed `/pack/PROMPT.md`. Scored on the bench by
`tasks/planner/meta/score_real02.py`, which first reproduced all six recorded selector verdicts of the original sets.
Private: `tasks/planner/real-02/review-v1/` (the reviewed sets, both reviews, the sessions, `bench-scores.txt`).

| Set | Passes the fix | False positives (of 6 hidden FAIL) | False negatives (of 6 hidden PASS) |
|---|---|---|---|
| set 1 | no (3 tests fail) | 1 | 4 |
| set 2 | no (3) | 2 | 6 |
| set 1, reviewed | no (6) | **0** | 6 |
| set 2, reviewed | no (7) | **0** | 6 |

- **The review removed every false positive and rejected every correct answer, the owner's own fix included.** It
  traded one error for the other: a selector that accepts nothing has no false positives.
- **Scored on all twelve attempts, the original sets were already too strict** (4 and 6 of 6 correct answers
  rejected). The first run's "0 of 7 false negatives" held only because each set judged attempts made by executors
  who had been shown that set and wrote to it.
- **What the fix fails is not wrong tests but a higher bar.** The reviewed sets ask `AGENTS.md` to mention CI's
  `npm audit` gate, the GitHub Pages workflow, Dependabot, `auto-update.sh` and every npm script, and to drop a
  stale claim that command tests exist. Each is defensible under "up to date"; the owner's fix does none of them.
  Asked "too strict?", the reviewer measured against its own reading of the request, not the owner's.
- **So the gap is the request, not the test writer.** How complete "make sure @AGENTS.md is up to date and clean"
  has to be is in the owner's head, not the repository; no amount of reviewing recovers it. The work packages, whose
  prompts name files and behaviour, had no false positives in the first run for the same reason.

**What this changes.** For a vague request, a planner's tests are a guess at the owner's bar, and the guess is the
error. The next candidate is a checkpoint, not a better reviewer: the planner lists what it reads "done" to mean
(for `real-02`, the reviewers' lists are ready-made), the owner keeps or strikes each line, and the tests are written
to the confirmed list. That costs the owner a minute a task and changes the unattended claim of milestone 5 to
"unattended after one confirmation". Whether that is acceptable is the owner's call.

**Next, after this:**
1. ~~Owner's call: the confirmation checkpoint for vague requests, or keep vague requests out of the unattended path.~~
   The checkpoint (owner, 2026-11-01: "if my prompts get turned into requirements or specs that I don't agree with
   I'll want to be able to refine them like I do in a session like this"). See "Confirmation checkpoint" below.
2. With a checkpoint, a bench test that needs no runs: strike the reviewed sets' items the owner's fix does not
   cover, and score the result on the twelve attempts.
3. The new vague tasks and the power-sized run as before, with whichever selector survives.


## Confirmation checkpoint (2026-11-01)

The owner's choice after the review step: for a plain-language request the planner's reading of "done" is shown to
the owner, who keeps, strikes or rewords each line before any test is written. Milestone 5's claim becomes
"unattended after one confirmation".

**A bench test first, with no runs.** Each reviewed set's tests were struck where they checked something the owner's
own fix chose not to do (CI's `npm audit` gate, the GitHub Pages workflow, Dependabot, `auto-update.sh`, every npm
script, every `src/` directory, the stale "command tests" line it kept): six tests a set, struck by requirement, not
by result. Scored on the twelve attempts (`tasks/planner/real-02/review-v1/bench-scores-confirmed.txt`):

| Set | Passes the fix | False positives (of 6 hidden FAIL) | False negatives (of 6 hidden PASS) |
|---|---|---|---|
| set 1, reviewed, struck | **yes** | **0** | 2 |
| set 2, reviewed, struck | no: one Windows bug (below) | 0 | 6 |
| set 2, reviewed, struck, the bug's test also skipped | **yes** | **0** | 2 |

- **The first selector to pass the fix and reject all six wrong answers.** The struck set 1's two "false negatives"
  are an attempt that dropped the release workflow's description and one that documented four of the five newer
  modules; the hidden tests let both through (they check neither the release section nor all five). Each is a
  judgement the owner's list would settle.
- **This is the owner's bar applied by hand, with the fix in view.** It shows the selector is right once the bar is
  known, not that a planner's list makes the bar easy to apply. That is the end-to-end test below.
- **A separate bug: the planner's tests ran on Linux, the harness on Windows.** Set 2's reviewed path check built paths
  with `path.join` and split them on `/`, so on Windows every bare file name (`backup.sh`, `schema.ts`) counted as
  missing and the check failed every attempt. The planner validated its tests in the Linux container; the harness
  runs them on the desktop. No confirmation can catch this; the tests prompt now says the tests run on Windows too.

**How it runs.**

1. `desktop/scripts/run-planner.ps1 -Phase done` (prompt `DONE-PROMPT.md`): the planner writes `DONE.md` and nothing
   else, a checklist in three parts: **Must do** and **Must keep** (ticked), **Could do (not clearly asked)** (unticked,
   where a vague request's generous end goes).
2. The owner reviews it, in a chat with the main seat like any plan: keep, strike, reword. `desktop/scripts/
   planner_done.py` shows it (`show`), applies ticks (`set D3=off C1=on`) and records the confirmation (`confirm --by
   owner`): one comment line with the sha256 of every item line, so any later tick or edit voids it.
3. `make-planner-packs.py --confirmed <dir>` copies only confirmed, unchanged lists into the pack, and
   `run-planner.ps1 -Phase tests` (prompt `TESTS-PROMPT.md`) checks each one again (`planner_done.py verify`) before
   it touches Docker. The planner writes tests for the ticked lines only, each named by its id, and none that
   requires an unticked line.

`-Phase plan` (the default) is the first run's single step, unchanged, so that run can be repeated. The prompts are
private (`tasks/planner/DONE-PROMPT.md`, `TESTS-PROMPT.md`). Guard: `tests/test-planner-done.ps1` (the parser and
confirmation, the pack builder's refusal, and `run-planner.ps1 -Phase tests` refusing a missing, unconfirmed or
edited list before Docker, on a token file that does not exist so no session can start; each refusal was disabled
once to check that the guard goes red).

**End to end on `real-02` (2026-11-01).** Done phase: 65 s, $0.40, a 32-line `DONE.md` (14 must do, 9 must keep, 9
could do). The owner's answer: "All fine", confirmed as written (23 kept, 9 struck). Tests phase: 311 s, $0.62, one
file with 23 tests, one per kept id and none for a struck one. On the bench
(`tasks/planner/real-02/checkpoint-v1/bench-scores.txt`): **0 false positives of 6**, but every hidden-PASS attempt
and the owner's fix rejected.

- **One of those six "correct" attempts is not.** It demoted every section heading from `##` to `###`. The hidden
  test's `toContain('## Project')` matches `### Project` as a substring, so it passed; the planner's must-keep tests
  failed it on six items. A hidden-test bug, found by the planner's tests.
- **The fix fails only must-do items, never a must-keep one:** six it does not do (`npm audit`, the Pages workflow
  twice, the stale "command tests" line, "`tests/` mirrors `src`", the dash style) and five where it names the
  concept but not the specifics the line named (`listing-expiry` and `digest-state`, customIds "rather than
  hand-written formats", `/admin history`, the Docker healthcheck).
- **So the checkpoint works mechanically and the review is the weak step.** Thirty-two detailed lines were confirmed
  in one reply, including specifics the owner's own fix does not meet. A list that is easy to say "all fine" to
  needs to be short and say goals, with examples marked as examples. That is the done prompt's next version; whether
  the owner's bar is the confirmed list or the fix is the owner's to say.

## The owner's bar, version 2 (2026-11-01)

After the end-to-end run the owner answered three questions, each split into what they would **accept** and what they
would **ideally** want (owner: "the former is a lot more ambitious than the latter"):

| Question | Accept | Ideal |
|---|---|---|
| The owner's own `real-02` fix, handed in by an agent | merge it as is | all nine extra items (npm audit, Pages, the stale lines, every module, Dependabot, `auto-update.sh` ...) |
| Which error is worse | small gaps merged, tidied by later cleanup runs ("don't let perfect be the enemy of good"), with metrics to show improvement | never merged: lost content, wrong claims, failing existing checks, changes outside the request |
| Review time | scales with the task; a complicated plan waits for undivided attention | a summary first with the detail under it, like work items with sub-items on a board |

So one list was doing two jobs. Version 2 separates them, and adds the never-merge rules as standing checks.

**DONE.md version 2** (`DONE-PROMPT.md` v2, `desktop/scripts/planner_done.py`):
- **Gate**: what the owner would accept. Its tests decide merge or retry; a few goals, not every name.
- **Ideal**: what the best answer would also do. Its tests run on every attempt and never block one.
- **Out of scope**: noted, never tested, never ticked.
- Items have sub-items (`G1`, `G1.1`); striking a parent strikes everything under it. A `Size:` line says how long
  the review takes. The confirmation hash covers each item's tier too, so moving a line between sections voids it.
- The done prompt no longer lists the standing checks; the tests prompt (v2) writes the Gate set to `<run>/` and the
  Ideal set to `<run>-ideal/`, so the harness cannot mix them up.

First lists, for `real-01` to `real-03` (17 to 42 s, $0.67 for the three; private `tasks/planner/<task>/checkpoint-v2/`):
1- and 2-minute reads of 4 to 5 Gate goals each, against version 1's 32 lines for `real-02` alone. They wait for the
owner's confirmation.

**Standing hard blocks** (`tests/checks/doc-integrity.ps1`, the `integrity` gate in `test-tasks.ps1`): on every
attempt, whatever the task's own tests say, a Markdown heading the base had that is gone or at another level, a deleted
Markdown file, or a path the change adds that is not in the repository fails the run, and `run-retries.ps1` and
`summarize-rounds.ps1` never keep it. Existing checks failing and changes outside the request were already blocks (the
suite and scope gates, the tamper check). On the `real-02` bench the gate fails exactly the two attempts that lost
content (the dropped `## Project`, one of the first run's three false positives; the demoted headings, which the hidden
tests passed) and passes the owner's fix and the other nine.

**The Ideal metric** (`test-tasks.ps1 -IdealDir`, recorded as `ideal`: done of total and which ids): scored per item from
the test names, never read by a gate, the dispatcher or the summary's "accepted"; `summarize-rounds.ps1` reports the
share done per model and arm, and how often the integrity gate blocked. The ideal tests are not shown to the model:
this measures what a model does beyond the gate unprompted. Showing them would be its own arm.

Guards: `tests/test-doc-integrity.ps1` (19 scenarios in a throwaway repo, the dispatcher's verdict, the harness wiring),
`tests/test-ideal-tier.ps1` (the scoring on vitest's output shapes, the summary, and that nothing gates on it),
`tests/test-planner-done.ps1` (now 28 unit tests). Each rule was disabled once and its guard went red; two of the
guards needed a sharper case before they did.

## The checkpoint, live (2026-11-02)

The owner confirmed the three v2 done lists as written ("All good"), the planner wrote Gate and Ideal sets from them
($1.74 for the three), and `run-retries.ps1` ran `real-01`, `real-02` and `real-03` from node3 against the server's
`qwen3.6`, the Gate set as the selector, the Ideal set measured, the executor shown the Gate tests (private
`results/exp3-checkpoint-v2-live`).

| Task | Attempts | Planner's Gate | Hidden tests | Ideal done | Integrity |
|---|---|---|---|---|---|
| `real-01` | 2 | PASS, PASS | PASS, PASS | 4/4, 4/4 | attempt 1 a false block (branch names), attempt 2 PASS |
| `real-02` | 3 | PASS ×3 | PASS ×3 | 5/5, 5/5, 4/5 | all three false blocks (`` `.github/` ``) |
| `real-03` | 1 | PASS | PASS | 6/7 | PASS |

- **All six attempts passed the planner's Gate and the hidden tests.** The only rejections were two integrity false
  blocks, fixed the same day (#190, #191); under the fixed rule every task is accepted on its first attempt, with no
  false positive and no false negative, and 4 to 7 Ideal items done.
- **Why this differs from the bench:** on the bench the same strict `real-02` Gate rejected every saved attempt,
  including the owner's fix, because none of those executors had seen it. Shown the confirmed tests, the executor
  met them, the stricter lines included, and still passed the owner's hidden tests. The owner's review is what keeps a
  strict Gate honest; delivery of near misses (below) is the release valve.
- The bench result for the v2 `real-02` set itself (`checkpoint-v2/bench-scores.txt`): 0 of 6 wrong attempts kept, 6 of
  6 right ones rejected. Two of its tests are stricter than their lines (G2.1 treats an "e.g." list as exhaustive; G1.1
  requires prose around `HEALTH_PORT`), despite the tests prompt saying "e.g." means examples.

## The checkpoint, again under the new settings (2026-11-05)

The live round of 2026-11-02, repeated on the server's seat with the thinking budget and the 4,096 batch (private
`results/planner-gated-r{1,2}-20261105`): `real-01`, `real-02` and `real-03`, the confirmed v2 Gate set as the selector
the model is shown, the Ideal set measured, the hidden tests as the judge, up to 3 attempts, two reps, driven from
node3's CPU.

| Measure | 2026-11-02 (old settings) | 2026-11-05, 2 reps |
|---|---|---|
| Accepted | 3 of 3 tasks (`real-02` only after the integrity fixes) | 6 of 6 runs, every one on its first attempt |
| Planner's Gate against the hidden tests | 6 of 6 attempts agreed | 6 of 6 agreed: 0 false positives, 0 false negatives |
| Integrity blocks | 5 false blocks (fixed the same day) | 0 of 6 |
| Ideal items done | 28 of 30 over all attempts; 15 of 16 on first attempts | 27 of 32 (84%): 13 of 16 and 14 of 16 |
| Time per attempt | `real-01` about 3.5 minutes | 1.4 to 3.5 minutes (`real-01` 1.4 to 1.6) |
| Steps cut by the output limit | not recorded | 0 of 6; none reached 8,192 tokens in a step |

- **The gate held.** Over both rounds, 12 attempts the dispatcher accepted and none wrong by the hidden tests: 0 of 12
  (95% interval 0% to 24%). The 10% line needs about 30 to 35 such attempts, which only real work will supply.
- **The Ideal score is a little lower, and it is the same two items both times.** `real-03` missed I5 (the Terms say
  the bot does not process payments) and I6 (the README's privacy section points to the Privacy Policy) in both reps
  (5 of 7 each; 6 of 7 on 2026-11-02), and `real-01` missed one item in rep 1. Ideal never gates, so these were
  accepted as they should be: the lenient bar, with a later cleanup run for the rest. Six runs cannot say whether
  the dip is the settings or the sample.
- **Nothing here needed a retry,** so the feedback-between-attempts idea (attempt 2 sees attempt 1's failed Gate
  tests) has nothing to improve on these tasks.

## Real work: intake, delivery and the owner's verdict (2026-11-02)

One task from the owner, from request to a branch to review, with `tests/new-real-task.ps1`:

```powershell
pwsh -File tests\new-real-task.ps1 -Step add -Id lfc-w01 -Repo M:\Projects\LFCbot -Title "..." -Prompt "<the request>"
pwsh -File tests\new-real-task.ps1 -Step done  -Id lfc-w01     # the planner's done list, shown for review
python -I desktop\scripts\planner_done.py confirm <HomeLab-private>\tasks\real-work\lfc-w01\1\DONE.md --by owner
pwsh -File tests\new-real-task.ps1 -Step tests -Id lfc-w01     # Gate and Ideal tests from the confirmed list
pwsh -File tests\new-real-task.ps1 -Step run   -Id lfc-w01     # attempts against the server, up to 3
pwsh -File tests\new-real-task.ps1 -Step deliver -Id lfc-w01   # the branch fleet/lfc-w01
pwsh -File tests\record-verdict.ps1 -ResultsDir <...>\results\real-work\lfc-w01 -Task lfc-w01 -Verdict merged
```

- **Its own manifest:** `HomeLab-private/tasks/real-work/manifest.json`, not the benchmark's (`build_manifest.py`
  regenerates that one). Base = the repository's HEAD; `grading: "checklist"` (there are no hidden tests; the harness
  records the hidden-test verdict as MANUAL); its checklist is the confirmed `DONE.md`; the test command is copied from
  a benchmark task of the same repository.
- **Every attempt's change is kept** as a `.patch` beside its run JSON (`patchFile`), written by git itself so CRLF and
  binary content survive; before this an attempt's change died with its sealed checkout.
- **Delivery** (`tests/deliver-attempt.ps1`): the latest accepted attempt (the dispatcher's own rule, read from
  `run-retries.ps1`); if none, the near miss with the fewest failed Gate tests among attempts that broke **no** hard
  block (integrity, suite, scope, tampering), labelled `NEAR MISS` with its failing count; if only hard-block failures,
  nothing. The branch is made in a temporary worktree at the base: the owner's working copy, current branch and `main`
  are never touched, and nothing is pushed. The commit message carries every gate's verdict and the Ideal score.
- **The owner's verdict** (`tests/record-verdict.ps1`): merged, fixed (merged after changes) or rejected, with a note.
  For real work this is the truth the gate is measured against: an accepted delivery rejected is a false positive, a
  near miss merged as is a false negative.
- Guards: `tests/test-deliver-attempt.ps1` (33 checks: the choice of attempt, hard blocks never delivered, `main`, the
  working copy and the remote untouched, CRLF byte for byte, the branch suffix, the verdicts), `tests/test-new-real-task.ps1`
  (the manifest entry, its refusals, and `run` stopping before anything runs on an unconfirmed list). Writing the first
  guard caught a real bug: the hard-block test read the dispatcher's first rejection reason, which names the selector
  before the hard blocks, so an integrity-blocked attempt that also failed a planner test was delivered as a near miss.

## Local planner against Opus (2026-11-05/06)

Experiment 3's planner prompts on the local `qwen3.6` instead of Opus, to see how much planning needs a frontier model
(`desktop/scripts/run-planner-local.ps1`, PR #214; private `results/planner-local-20261105`). Same tasks, same pack,
same prompts with only the mount points moved. A fourth arm, **guided**, adds a short list of general checks to the
prompts (`guided-rules.md` there). No owner input was used overnight: the tests phase worked from the lists the owner
had already confirmed on 2026-11-02, and those were written by Opus.

### Results

| Step | Local, plain prompt | Local, guided prompt | Opus |
|---|---|---|---|
| Plan phase, sets valid (fail on the base, pass on the real fix) | 0 of 12 | 4 of 12 | 8 of 12 |
| Done lists a reader can use as they stand | thin, misses the traps (below) | not run | confirmed by the owner as written |
| Gate sets from the confirmed lists, valid on the same check | 1 of 12 | 2 of 6 | 0 of 3 |
| Executor shown those Gate sets: kept attempts passing the hidden tests | 12 of 12 | 12 of 12 | 6 of 6 |
| Accepted on the first attempt | 9 of 12 | 11 of 12 | 6 of 6 |
| Ideal items done, measured on the same Opus-written Ideal sets (the owner's own fix: 5 of 16, 31%) | 14 of 64 (22%) | 17 of 64 (27%) | 27 of 32 (84%) |
| Planner cost for the three `real-*` tasks | about 20 minutes of GPU time | about 20 minutes of GPU time, using the plain list step | $2.41 |

Ideal, all local: 31 of 128 (95% interval 18% to 32%); Opus: 68% to 93%. Hidden tests: 0 of 24 kept attempts wrong, 95% interval
0% to 14%. The 24 runs share 3 tasks and 4 sets, so those intervals are narrower than the evidence is. The Opus figures come from
the 2026-11-05 round on the server's seat. Each local arm ran on both seats, and the seats did not differ (15 of 64 and 16 of 64
Ideal). Comparisons between planners, by the correct paired test, are in "Audit of these numbers" below.

### What this says

- **The hidden tests held, and local-gated work sits near what was shipped** (the Gate itself has a hole: see the review
  below). Every kept attempt passed the owner's hidden tests. The executor did about a quarter of the Ideal list with local Gate
  tests, and 84% with Opus's in front of it. The owner's own fix scores 31% on that list, so local-gated work is near what was
  shipped, and Opus-gated work goes well past it. A demanding Gate may be why, but it is not shown: Opus wrote both that Gate
  and the Ideal sets, so shared wording could explain part of it.
- **The hidden tests cannot see what the Ideal list asks for.** Of the 8 kept Privacy Policies on `real-03`, 2 say `/delete` removes
  the listing from the database, which is what confirmed item G3.2 exists to prevent; 3 are vague, 2 are right, 1 says nothing.
  One of the 2 came from a set that scored valid, so its test did not hold the line either. **The owner's own policy says the same
  ("Removed immediately upon your request") and fails G3.2**, while the code only sets a status. Two kept runs also added a
  `vitest.config.ts` nobody asked for, apparently because that Gate set failed to load without `globals`; the scope gate allows a
  new config file. Both are things only review catches today.
- **"Valid" does not work as a score for Gate sets from a confirmed list.** Opus's own sets fail on the owner's real fix
  (0 of 3), because the confirmed lists ask for more than that fix did. It still works for the plan phase, where the
  bar is the request alone. Local Gate sets are not worse by this measure; it just cannot rank them.
- **The local planner's first failure looked like following instructions; see the review below, which corrects this.** In
  the plain plan phase, 5 of the 12 sets passed on the base. Both `wp-1a` sets were existing tests the harness hides, not
  careless copies, and three others lost a folder path so the runner never found them. The other 7 failed on the real
  fix, mostly for over-strict wording (one `real-02` set did not load). The stricter checks cost no time on balance: +17% on these
  six tasks, -16% on the held-out nine.
- **Done lists are the frontier model's clearest lead.** All 12 local lists have the visible facts (missing variables,
  the two files, the README links). None of the 4 `real-03` lists has the `/delete` trap, none of the 4 `real-01` lists
  says the work stays off `main`, and one marks the Testing and Behavior Notes sections "already accurate" when the repo
  contradicts them. Formats slip too: a Gate with every box unticked, an out-of-scope item ticked, one item that bars
  "somewhere else appropriate", which the request allowed.
- **Reading only.** The audit flagged 1 run of 54, a false alarm (`findstr /C:"FAIL"` read as a path, since fixed). There
  is no container here: this detects a read outside the scratch folder, and does not prevent one.

### Not tested yet

**A pipeline with no frontier model at all.** Every Gate set above came from a list Opus wrote. A local list through to
a local executor needs an owner to confirm the list, so it was left for the owner. The owner's 2-minute edit of a
local list is the cheapest thing left to try: this data suggests the list is where the planner earns its money, and an
owner adding the traps may be worth more than the rest of the planner.

### A held-out check of the stricter prompt (2026-11-06)

The stricter prompt was written after seeing the plain prompt fail on the six tasks above, so its 4 of 12 could have been
flattering. This reran both prompts on nine benchmark tasks with hidden tests and a known-good fix that were not used last
night (`wp-0a`, `wp-2b`, `wp-3a`, `wp-3b`, `wp-4a`, `wp-5a`, `wp-6a`, `wp-7a`, `wp-9a`), one run each per prompt, split across
both seats (private `results/planner-heldout-20261106`). The same check as before: a set is valid if it fails on the
original code and passes on the real fix. No audit flags in 18 runs.

| | Plain prompt | Stricter prompt |
|---|---|---|
| Valid sets | 2 of 9 (`wp-0a`, `wp-2b`) | 3 of 9 (`wp-2b`, `wp-3a`, `wp-6a`) |
| Passed on the original code | 5 | 4 |
| Failed on the real fix | 2 (`wp-6a` one test; `wp-3a` did not load) | 2 (`wp-4a` six tests; `wp-9a` one test) |

Pooled with the first six tasks, plain is 2 of 21 (10%, 95% interval 3% to 29%) and stricter is 7 of 21 (33%, 17% to 55%). Paired,
stricter did better in 6 pairs and worse in 1. Opus got 8 of 12 on the first six tasks only.

- **As handed in, the stricter prompt's lead is not proven.** Its rate held (3 of 9 here, 4 of 12 before) and the plain
  prompt did better on these tasks (2 of 9 against 0 of 12). The review below moves the misplaced files, and that changes
  this conclusion.

### Review of these results before changing anything (2026-11-06)

Before building the runner change proposed above, every set was re-read against its transcript, and the misplaced sets
were moved to where the model had worked on them and validated again, with nothing else changed (private
`results/planner-review-20261106`; no model time). This corrects several things written above.

**Why the 42 plan-phase sets failed:**

| Cause | Plain (21) | Stricter (21) |
|---|---|---|
| Valid as handed in | 2 | 7 |
| Valid once moved to where the model worked | 0 more | **4 more** (11 of 21) |
| Lost its path, and still too strict or wrong once moved | 3 | 2 |
| Written straight to the output folder, never in the clone; too strict or wrong once placed (the home is my guess) | 2 | 1 |
| Handed in the repository's existing failing tests, which the harness hides | 4 | 0 |
| Edited an existing test file the harness hides | 1 | 0 |
| Handed in the document itself (`AGENTS.md`), no test | 0 | 1 |
| Too strict or wrong where it stood, or did not load | 9 | 6 |

Corrected conclusions:

- **The stricter prompt probably helps; the audit below has the paired tests.** With placement repaired it is 11 of 21 against 2 of 21
  (95% intervals 32% to 72% and 3% to 29%), better in 9 pairs and worse in none. This repair was chosen after seeing the data, so treat
  it as a strong hint. On the first six tasks it is 6 of 12 against Opus's 8 of 12, where as handed in it was 4 of 12. The earlier
  "not shown to help" came from placement errors hiding part of the gain. The plain prompt's own sets gain nothing from the repair.
- **"Copied existing tests" was mostly a benchmark artifact.** 8 of these 15 tasks exclude test files by name, and the three I checked (`wp-1a`, `wp-7a`, `wp-9a`) start from a test-first
  "contract" commit: failing tests for the feature are already in the repository, and the harness hides them. The planner found
  them, ran them, saw them fail ("The tests already exist") and handed them in, which is what the prompt asks for apart from
  "new files only". The harness then hid them, and the set scored as passing on the base. An ordinary repository would not
  do this, so it should not drive a fix, though it does flatter the stricter prompt's lead (its "new files only" rule avoids it).
- **Placement is a real cause but not the main one.** Tests too strict for the real fix are the larger limit: 14 of the
  plain sets and 9 of the stricter ones once placed, on many of the same tasks where Opus also failed (`real-02`, `wp-5b`).

**A hole in the gate, found on the way.** A Gate set moved to the wrong depth climbs out of the checkout: `../../AGENTS.md`
from the checkout's top folder is `tests/AGENTS.md` in the harness's own repository. Executors met the failing test by
creating that file there, so the Gate read a stray copy and not the delivered work. In one attempt the checkout had **no
changes at all**, the Gate passed, and only the scope gate stopped it. On another set an executor made a Windows junction
beside the checkout through the shell, which `outsideWrites` cannot see, since it reads only the edit and write tools and is
never graded. These leftovers also survive between attempts.

- **10 of the night's 24 kept runs used a set like this** (5 set and task pairs, each on two seats). Not all were traced.
- **The hidden tests are unaffected:** they ran on the checkout, so 24 of 24 stands. What falls is any reading of those 10 Gate
  passes as evidence, and the Gate's value as the only judge on real work with no hidden tests.
- **Earlier Opus-gated rounds look clean:** `planner-gated-r1`, `r2` and `exp3-checkpoint-v2-live` recorded no outside writes
  (shell writes would not show), and Opus's Gate sets have no such climb. So the 0 of 12 stands, on that evidence.
- **The hole does not explain the thin work.** Ideal was no lower on runs whose Gate read outside.

**What to change, in order:**

1. **Close the hole first.** After a Gate passes, run it again on a clean copy of the base in a different folder, with only the
   attempt's patch applied. Stray files, junctions and leftovers are simply not there, whichever tool made them. This matters
   more than any planner change, because real work has no hidden tests behind the Gate.
2. **Collect the planner's files from its clone** (the change proposed above). It fixes the placement failures in both phases,
   including the climbing-out above when the cause is a moved file. A planner that wrote outside its clone then shows up as no
   output, not as a set that looks fine.
3. **Check each set before use, without knowing the solution:** it must load, the runner must find it, and it must fail on the
   base. One retry with the error as feedback. This catches the sets with load errors, which are model bugs a collector cannot fix.
4. **Adopt the stricter prompt's rules.** They cost no planner time on balance. Adopted 2026-11-07: they are now in the private
   `PROMPT.md` and `TESTS-PROMPT.md` (version 3), so a later round is a new era for the planner. Every Opus set so far used version 2.

**Fix 1, built and run live (#218, 2026-11-06).** On the desktop's CPU with the server's model (private
`results/recheck-live-20261106`), up to 2 attempts each. The clean-copy run took 15 to 21 seconds.

| Set | Attempts | Gate in the checkout | Clean copy | Hidden tests | Outcome |
|---|---|---|---|---|---|
| 3 honest sets (`guided-r1`, `real-01` to `real-03`) | 1 each | PASS | PASS | PASS | all 3 kept, first attempt |
| `plain-n3r2`, `real-03`, attempt 1 | changed nothing in the checkout | PASS | not run | FAIL | scope gate rejects |
| `plain-n3r2`, `real-03`, attempt 2 | | PASS | FAIL (22 tests) | PASS | rejected: good work, broken set |
| `plain-srv2`, `real-02`, attempts 1 and 2 | | PASS | FAIL (did not load) | PASS | rejected: good work, broken set |
| `guided-r2`, `real-02`, attempt 2 (attempt 1 timed out) | | PASS | FAIL (did not load) | **FAIL** | **rejected: the old Gate would have kept wrong work** |

- No honest set was blocked, and the hole is closed: every set that climbs out was rejected.
- **The cost is that a broken set now blocks good work:** 3 attempts the hidden tests pass were turned away, and the delivery
  falls back to a labelled near miss for review. That is the right failure, since nothing could vouch for them, but it
  raises the priority of fixes 2 and 3, which stop broken sets reaching an executor at all. Three sets is a small sample.

**Fix 2, built and run live (#219, 2026-11-06).** The runner takes each set from the planner's clone. The same 21 plan-phase runs
with the stricter prompt, plus 6 tests-phase runs, on both seats (private `results/planner-collect-20261106`):

| The 21 plan-phase runs | Valid | Passed on the original code (tests mostly never ran) | Too strict or wrong | No set |
|---|---|---|---|---|
| Plain prompt, as handed in | 2 | 10 | 9 | 0 |
| Stricter prompt, as handed in | 7 | 8 | 6 | 0 |
| Stricter prompt, files moved by hand afterwards | 11 | 2 | 8 | 0 |
| **Stricter prompt, collected from the clone, live** | **8** | **0** | **9** | **4** |

- **It did not reach the 11 the hand repair suggested.** 8 of 21 (95% interval 21% to 59%) is one more than as handed in, with 5 pairs
  up and 4 down. Against the plain prompt's 2 it is 6 pairs up and none down, and on the first six tasks it is 5 of 12 against Opus's 8
  of 12. The hand repair was picked after seeing the data, so its 11 was optimistic.
- **What it did do is end the silent failure.** Sets that pass on the original code went from 8 to 0: every set handed over now
  runs and fails first. The failures left are visible: 9 sets too strict or wrong, and 4 with no set (1 handing back only the
  repository's own tests, 1 writing nothing, 2 at the root).
- **The tests phase:** none of the 6 sets climbs out of the checkout (5 of 12 before, a different sample), so fix 1 should have
  less good work to turn away. 1 of 6 is valid on the real fix, which still cannot rank them (Opus's own: 0 of 3), and 1 does not load.
- **Too strict is now the limit:** 9 of 21, and no runner change can see it without the solution.
- **The first version had a bug the live run found.** A planner may write its test in the output folder at the right path, copy it
  into the clone to run it, and remove it again. The collector dropped those as "never in the clone", 8 sets in this round. The rule
  was corrected (a hand-in stands when its top-level folder exists in the repository) and applied to this round afterwards from the
  saved hand-copies, then validated, so those 8 did not run live with the corrected code.

None of these touch the biggest gap: Ideal at 24% against 84% (the owner's own fix: 31%), and the items missing from the local done
lists. That needs the owner-edited local list test ("Not tested yet" above), which matters more to the budget question than any of the four.

### Audit of these numbers (2026-11-07)

Before any more testing, every headline number from 2026-11-01 on was recomputed from the raw run JSONs with a separate pass rule,
and the statistics were checked against textbook values (private `results/audit-20261107`). No model time.

**What held.** Every count, every Wilson interval and the runs-needed table recomputed as written, for the regression, thinking
budget, retry loop, planner screen, checkpoints, local rounds and North. One apparent difference is not an error: `outputCapHit`
marks a run's last step only (11), and the 12 quoted is runs with any step at the limit, from the transcripts.

**What was wrong, all corrected in place above:**

| What was written | What is right |
|---|---|
| Fisher's exact test on pooled runs, for prompts and planners | The wrong test: runs cluster by task, as the 2026-10-23 review had already said, and these comparisons are paired. See the table below. The older Fisher values in `roadmap.md` have the same flaw, but all are "not shown", so no conclusion changes |
| "The work got thinner", local against Opus on Ideal | The owner's own fix scores 5 of 16 (31%) on that list. Local-gated work is near what was shipped; Opus-gated work goes well past it |
| "A demanding Gate is what makes the executor do more" | Not shown. It may be true, but Opus wrote both that Gate and the Ideal measure, so shared wording could explain part of the 84% |
| The `/delete` claim was the model's failure | The owner's own policy says "Removed immediately upon your request" too, and it fails G3.2. The code only sets a status (`src/services/listings.ts`) |
| "Stricter prompt costs about 15% more time" | +17% on the first six tasks and -16% on the held-out nine: no cost on balance |
| About 3 lines against 6 to 7 on `real-01`, about 20 against 36 on `real-02` | Those counts left out blank lines. See the table below |
| "Valid" as a whole verdict on a set | On `wp-6f` the task's test command runs only `apps/server`, so the `apps/web` tests in its sets never ran, Opus's and local's alike |

**Paired comparisons** (same task and run number; exact two-sided sign test; "up" means the first did better):

| Comparison | Pairs: up, down | p, by pair | Tasks: up, down | p, by task |
|---|---|---|---|---|
| Stricter as handed in, against plain (21 pairs, 15 tasks) | 6, 1 | 0.13 | 5, 1 | 0.22 |
| Stricter moved by hand, against plain (chosen after the data) | 9, 0 | 0.004 | 7, 0 | 0.016 |
| Stricter collected from the clone, against plain | 6, 0 | 0.03 | 5, 0 | 0.06 |
| Collected, against stricter as handed in | 5, 4 | 1.0 | 4, 3 | 1.0 |
| Opus against plain (12 pairs, 6 tasks) | 8, 0 | 0.008 | 4, 0 | 0.13 |
| Opus against stricter as handed in | 4, 0 | 0.13 | 3, 0 | 0.25 |
| Opus against collected | 3, 0 | 0.25 | 3, 0 | 0.25 |
| Opus against moved by hand | 2, 0 | 0.5 | 2, 0 | 0.5 |

- **The stricter prompt probably helps, though the evidence is modest and partly flattered.** It never lost by more than one pair.
  Its "new files only" rule also avoids the repository's existing tests, which cost the plain prompt 4 sets and which an ordinary
  repository would not have. These tests were chosen after looking, with no correction for making eight of them.
- **Opus is never behind in a pair, and six tasks cannot show how far ahead it is.** A task-level sign test cannot go below 0.03 at 6
  tasks, or 0.25 at the 3 tasks that differ.
- **One run says little.** Between two samples of the same stricter prompt (as handed in, and collected), validity flipped in 9 of 21
  pairs, 5 up and 4 down. So one run of one task is weak evidence either way, and the collector's effect on validity is not visible
  through that noise. Its seats also differed from the earlier rounds: the nine held-out tasks all ran on node3's seat.

**The Ideal list against what was actually shipped:**

| Task | Owner's fix: Ideal | Local-gated | Opus-gated | Lines added: owner | Local-gated, mean | Opus-gated |
|---|---|---|---|---|---|---|
| `real-01` | 1 of 4 | 2 of 32 (6%) | 7 of 8 (88%) | 9 | 4 | 8, 9 |
| `real-02` | 2 of 5 | 18 of 40 (45%) | 10 of 10 (100%) | 18 (and 7 removed) | 21 | 35, 37 |
| `real-03` | 2 of 7 | 11 of 56 (20%) | 10 of 14 (71%) | 203 | 115 | 117, 133 |
| Total | **5 of 16 (31%)** | **31 of 128 (24%)** | **27 of 32 (84%)** | | | |

- **Read:** Opus's list is well beyond what the owner shipped, and the owner confirmed it as what the best answer would do. So the
  gap is what the frontier planner's bar buys over the owner's own level of finish. Local-gated work is close to shipped work on
  `real-02` (above it) and `real-03` (a little below), and well below it on `real-01`, where its short notes miss what the owner's
  nine lines included.
- **Limits:** three tasks, so no test at task level can pass 0.25, though all three lean the same way. The owner's fix was one commit
  made before the list existed. The lists were not compared on anything but these tests.

**Not checked:** rounds before 2026-11-01, and speed benchmarks (`bench-speed.tsv`), which were not recomputed.

### `kane-08` at a 60-minute limit (2026-11-05)

Four attempts on node3's seat (`results/window-limit60-kane08-20261105`, `-RunTimeout 3600`): 2 passed, at 55.6 and 15.2
minutes, and 2 still timed out. One of the two passes would have been lost at 45 minutes, so the limit does hide some
passes, but raising it does not fix the task: four attempts took 3.3 hours. Too few to change the default.
