# How we measure, and how sure we are

The one page on how this repo tests models and harnesses, and on how much each headline number can carry. Written
2026-11-03, audited 2026-11-07; the numbers in "How sure we are" are dated and move as rounds land. Terms: [glossary](glossary.md). The
limits that still apply are kept short in [methodology-caveats.md](methodology-caveats.md).

## What one measurement is

- **A task** is a real change from one of the owner's repositories, replayed at the commit before it: `kane-*`
  (KaneEnabler), `lfc-*` (LFCbot), `asohav-*` (ASoHaV). Its prompt says what to change. Its hidden tests come from the
  real fix and are never shown to the model unless the arm says so. Public tasks are in `tests/tasks/manifest.json`.
  The private ones (the `real-*` requests in the owner's own words, the `wp-*` work packages) are in HomeLab-private.
- **A run** is one non-interactive OpenCode session on one task, in a fresh sealed checkout at the task's pinned base,
  with a 45-minute limit (`tests/test-tasks.ps1`, driven by `tests/run-tasks-batch.ps1`, or `tests/run-window.ps1`
  for a night with no one there: [unattended-window.md](unattended-window.md)).
- **A run is graded by gates, not by reading it.** It passes when it stayed in scope, the repository's own suite
  passes, and the change is proven: a public task's hidden tests fail on the old code and pass on the new
  (`failsOnOld`); a real task's hidden tests pass. Further gates catch a model that described a change without making
  it (writes), edited the tests it was shown (tampering), or lost or broke documentation (integrity). The exact rule is
  in [tests/results/README.md → "What counts as a pass"](../tests/results/README.md#what-counts-as-a-pass).
- **A planner's Gate has to pass twice** (from 2026-11-06). An attempt the gates would otherwise keep has its Gate tests run again on the
  base plus only its patch, in a new folder under empty ones (`selector.recheck`), because a test at the wrong depth can read
  something outside the checkout. Anything but a pass rejects the attempt.
- **An infrastructure failure is not a measurement.** A run that never reached the model (host down, agent crashed)
  is filed as `_INFRA_`, not graded, and counted separately.
- **A timeout is a failure** (from 2026-11-12; owner, 2026-11-11). A run that hit the time limit reached the model and did not
  finish. It leaves only a `_TIMEOUT_` transcript, so `summarize-rounds.ps1` used to print how many there were and leave
  them out of every rate, which flattered a model that loops to the limit over one that fails quickly. It now counts each
  as a failed run of the model its file names. `-ExcludeTimeouts` prints the earlier view. **Numbers written before
  2026-11-12 are graded runs only unless they say a timeout was counted** (45 of 48 and North's 21 of 30 say so).
- **Conditions are kept apart.** Runs that showed the model tests (the task's own, or a planner's) are separate arms,
  marked by a file in their results folder, and never pooled with unassisted runs. Runs before and after a change to the
  engine, the agent, the plugins or a classifier are different eras: they are pooled only with a warning
  ([tests/results/README.md → "Era confound"](../tests/results/README.md#era-confound--read-this-before-comparing-seats)).

## What we report

`tests/summarize-rounds.ps1 -ResultsDir <folder>` prints all of these for any set of results:

| Number | What it answers |
|---|---|
| **Per-run pass rate**, with a 95% interval | How often one run of this model passes. The interval is the [Wilson score interval](https://en.wikipedia.org/wiki/Binomial_proportion_confidence_interval#Wilson_score_interval) (E. B. Wilson, 1927), which behaves at the small counts and near-0% or near-100% rates we have, where the textbook normal interval does not |
| **pass@k** and **pass^k**, means over tasks | Whether a task passes at least once in k runs, and whether it passes every time ([Anthropic, "Demystifying evals for AI agents"](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)). Work that runs unattended needs pass^k: a retry loop can recover from an occasional failure, but only if the failures are visible |
| **The gate against the truth** (planner arms) | How often the tests the fleet would accept work on (a planner's) passed work the hidden tests fail: **false positives**, the rate that decides whether unattended work can be trusted. Also false negatives (good work rejected), each with its interval |
| **Ideal share** | How much of the owner's "ideal" list the attempts did. Measured, never a gate (the owner's bar: [planner-tests-experiment.md → "The owner's bar, version 2"](planner-tests-experiment.md#the-owners-bar-version-2-2026-11-01)) |
| **Integrity blocks** | How often the documentation check stopped a run, so its false blocks stay visible |
| **Output cap** | How many runs lost a step to `limit.output`, how many failures had one, and the pass rate of runs with and without one (2026-11-03; the desk review that found 11 of 15 failures there had to count them by hand). If capped runs rarely pass, the extra room was not used; if they pass as often as the rest, the cap costs nothing (the "hit" against "no-hit" accuracy of [Mia and Amini, "Don't Overthink, Don't Underthink"](https://arxiv.org/abs/2608.26442)) |
| **Long steps** (`-StepTokens N`) | The same split for steps of N or more output tokens: the visible sign that a thinking budget (`--reasoning-budget N`) was reached, since OpenCode records no thinking tokens. Approximate: a step's output also holds its tool call |
| **Cost** | Passes per 100,000 output tokens and minutes per pass, the price of a pass rather than only its rate (Mia and Amini's "accuracy per reasoning token"). Compare it only between rounds of the same tasks: a round of hard tasks costs more per pass whatever the setting. Timed-out runs leave no run JSON and are not in it; the script prints their number |

For real work (a task from the owner, delivered as a branch) there are no hidden tests. The truth is **the owner's
verdict** on the delivered branch (merged, fixed, or rejected: `tests/record-verdict.ps1`), and a rejected accepted
delivery is a false positive.

## How sure we are (2026-11-07)

Intervals are 95% Wilson. "Enough to" says what the data can and cannot decide. Each number was recomputed from the run JSONs on
2026-11-07 ([planner-tests-experiment.md → "Audit of these numbers"](planner-tests-experiment.md#audit-of-these-numbers-2026-11-07)).

| Claim | Data | 95% interval | Enough to |
|---|---|---|---|
| `qwen3.6` passes small real tasks unassisted, today's settings | 45 of 48 runs, 16 tasks × 3 (2026-11-04; one timeout counted as a failure) | 83% to 98% | Call it a solid main seat |
| ...before the thinking budget and the 4,096 batch | 81 of 96 runs, 16 tasks × 6 (window 20261101-2213) | 76% to 90% | Say nothing regressed. Not that the settings raised the rate: task by task, 5 went up, 1 down and 10 stayed the same, and the seats differed. Two settings changed together |
| ...and passes them every time | 10 of 16 tasks passed all 6 runs; pass^6 0.625 (before the settings) | | Know which tasks are safe to hand off |
| A thinking budget stops the output-limit stall | 0 of 47 graded runs lost a step to it (2026-11-04), against 12 of 96 before | | Say the stall is gone. On the three worst tasks: 14 of 18 against 9 of 18, not proven at that size |
| North Mini Code is not an upgrade | 21 of 30 runs | 52% to 83% | **Not** to say it is worse at passing: telling 70% from 84% needs about 141 runs a model. The verdict rests on speed (about 3× slower per task) |
| A planner's tests can gate unattended work | 3 false positives in 28 accepted (screen, 2026-10-31); 0 in 12 with confirmed Opus lists (2026-11-02 and 11-05) | 4% to 27%; 0% to 24% | Find where the risk is (all three on one vague documentation request). Not to show the rate is under 10% |
| Local Gate tests, on Opus's confirmed lists | 24 of 24 kept attempts passed the hidden tests, but 10 of the 24 used a set reading outside the checkout (closed since by the recheck) | 86% to 100% | Say the hidden tests held. Not to trust those Gates: 3 sets, rechecked live, rejected wrong work once and good work three times |
| A local planner can write a valid set from the request alone | Stricter prompt 7 of 21 as handed in, 8 of 21 collected from the clone; plain 2 of 21; Opus 8 of 12 on six of those tasks | 17% to 55%; 21% to 59%; 3% to 29%; 39% to 86% | Say the plain prompt is not enough. Not to rank stricter against Opus: 6 tasks |
| Opus's confirmed bar gets more of the Ideal list | 27 of 32, against local-gated 31 of 128 and the owner's own fix 5 of 16 | 68% to 93%; 18% to 32%; 14% to 56% | See the gap, on 3 tasks. Not why: Opus wrote both that Gate and the Ideal tests |
| Tests shown to the model help | own tests 17 of 18; a planner's 25 of 35; none 13 of 18 | 74%–99%; 55%–84%; 49%–88% | Say the task's own tests help a lot. Not that a planner's help at all |

## How to compare two arms

- **Pair, and do not pool runs.** Runs of one task are correlated, so a test on pooled runs (Fisher's exact on two totals) overstates the
  evidence. When two arms ran the same tasks, count the tasks or pairs each won, and use an exact sign test. Report by task: that is the
  independent unit, and it also sets the limit. No result on 3 tasks can pass 0.25, and none on 6 can pass 0.03.
- **Keep the seats, days and settings the same** across arms, or say they differ.
- **Decide on the test before looking.** A test chosen after seeing the data is a hint, and several tests need a correction.
- **Replicate before believing a single run's verdict.** Two samples of one prompt differed on 9 of 21 pairs.
- **Give a measure a floor.** A score means little until the known-good answer has been through it: the owner's own fix scores 31% on
  the Ideal list, which changed what "24%" meant.
- **Prove a verdict covers what it claims.** A set counted valid only for the tests the task's command can reach (`testDir`), and a Gate
  can pass on files outside the checkout. Recheck any headline against the raw results before it goes in a report.

## How many runs a question needs

Size the runs to the question before running them, not by habit (owner, 2026-10-25). Runs a model (or an arm) for an
80% chance of detecting the difference at the 5% level:

| Question | Runs per arm |
|---|---|
| 50% against 84% (a big fix, such as the output cap on the worst tasks) | about 29 |
| 50% against 75% | about 58 |
| 84% against 95% (a good seat against a better one) | about 121 |
| 70% against 84% (North against `qwen3.6`) | about 141 |
| A false-positive rate is under 10%, if none is wrong | 35 accepted attempts (the "rule of three" gives 30) |

**These counts assume every run is independent, and ours are not** (added 2026-11-11). Runs of one task are correlated, so the
true numbers are larger, and by an amount this repo has not measured. Standard errors clustered on the unit that was sampled (here,
the task) "can be over three times as large as naive standard errors" on popular evals
([Anthropic, "A statistical approach to model evaluations"](https://www.anthropic.com/research/statistical-approach-to-model-evals)).
More runs of the same 16 tasks tighten each task's own rate and nothing else: a question about models in general needs more tasks.

What follows from the table:
- **Small differences between models are not worth buying with runs.** 141 runs a model is more than a night's
  window for `qwen3.6` alone, and about four nights for a model as slow as North (30 runs filled one). A model has to win by a lot, or on speed or cost, to be decided here.
- **Large effects are cheap.** A change that should move a task from failing half the time to rarely failing shows in
  a few hours, so fixes are tested on the tasks they target.
- **The gate's false-positive rate comes from real work**, not from more benchmark runs: each piloted task delivered
  and judged by the owner is one accepted attempt with a true verdict, and about 35 of them settle the 10% question.

## What the numbers do not cover

- **The Ideal list and the confirmed lists were written by Opus,** so their tests suit its Gate wording better than a local one.
- **The tasks are small and come from three repositories.** Large features (`large-f1`, `large-f2`) have never been
  rated. A pass rate here is a pass rate on this kind of task.
- **Runs of one task are not independent.** The per-run interval treats them as if they were, so it is narrower than it
  should be; pass^k per task is the more honest view for unattended use.
- **Small gaps are noise.** Infrastructure alone moved a public agent benchmark by 6 points, and Anthropic advises
  skepticism of gaps under 3 points ([Anthropic, "Quantifying infrastructure noise in agentic coding
  evals"](https://www.anthropic.com/engineering/infrastructure-noise)).
- **No contamination check.** The tasks are public commits; a model could have seen the fix in training.
- **Reviews are model-on-model.** The adversarial reviews were written by Claude about work Claude helped build. The
  owner's verdicts on real work are the first independent check.
- **Everything is dated.** A number holds for its model, engine version, agent version and settings; a change starts a
  new era.

## Re-deriving a number

```powershell
pwsh -File tests\summarize-rounds.ps1 -ResultsDir <HomeLab-private>\results\window-20261101-2213\baseline
pwsh -File tests\summarize-rounds.ps1 -ResultsDir <folder> -AsJson      # the same, as data
pwsh -File tests\summarize-rounds.ps1 -ResultsDir <folder> -ExcludeTimeouts   # as it printed before 2026-11-12
```

Every run leaves a run JSON (all gates and their details) and the raw transcript beside it; the summaries are
computed from those, never typed in. Where each round's folder is, and what it found, is in
[roadmap.md](roadmap.md) and [planner-tests-experiment.md](planner-tests-experiment.md).
