# Robot negative control — does `seam-checker.ps1` actually discriminate?

## Why this exists

`seam-checker.ps1` has only ever been run against one input: the one it was
written for. It returned RED-MARK, which matched the human audit, and the
round-2 comparison recorded that as "matched ground truth exactly."

That result is not evidence that the robot can tell a good plan from a bad one.
Every check is a literal string match against that one document, seam 3 passes
on the *absence* of a token, and RED-MARK fires whenever any single seam is
uncovered — so **RED-MARK is the robot's default output for essentially any
document, including an empty file.** A detector that always says "bad" agrees
with every bad input and has no demonstrated skill.

If the robot is to be kept as a regression gate on this plan — which is the one
role the round-2 correction leaves it — it has to be shown to return CLEAR when
the plan is genuinely fixed. That has never been tested.

## The fixtures

Both are derived from `raw/r2-remeasure-input.md` by surgical edit. Neither is
ever pasted to a model; these are inputs for the deterministic checker only.

**`raw/r3-robot-fixture-covered.md`** — seams 5 and 6 genuinely fixed:
- the Background test now names the pair in `commanders`
  (`[chooser, background]`), pastes the background, and asserts
  `commander.eligible true` — i.e. it walks the pairing/eligibility path the
  original test never entered;
- a new test, *"a banned commander cannot be named commander"*, ban-checks a
  resolved named commander directly rather than incidentally via the pasted
  list.

**`raw/r3-robot-fixture-reflowed.md`** — coverage **identical to the original**
(seam 5 still uncovered, seam 6 still uncovered in substance). The only change
is that one Section 2 sentence is re-worded and re-wrapped, moving the words
"commanders" and "banned" closer together. No check was added.

## Predicted results

Simulated against the robot's own regexes before writing this; the simulation
reproduces the committed `raw/r2-robot-output.md` exactly on the original
input, so the predictions below are falsifiable rather than hopeful.

| Input | Predicted verdict | Predicted seams |
|---|---|---|
| `raw/r2-remeasure-input.md` (baseline) | RED-MARK | 1–4 COVERED, 5 UNCOVERED, 6 UNCOVERED |
| `raw/r3-robot-fixture-covered.md` | **FIRST-RUN-SAFE** | all six COVERED |
| `raw/r3-robot-fixture-reflowed.md` | RED-MARK | 5 UNCOVERED, **6 COVERED** |

## How to read the outcome

**Baseline must reproduce.** If it does not, the robot's behaviour has drifted
since `0f76bb7` and nothing else in this round means anything.

**The covered fixture decides whether the robot has any skill.**
- FIRST-RUN-SAFE → the robot discriminates. It is sound as a regression gate on
  this plan: it goes green when the coverage is really there, red when it is
  not.
- RED-MARK → **the robot has no demonstrated skill at all.** It cannot go
  green, so its agreement with the human audit on the original input was
  coincidence, and it should not gate anything. It would need rewriting or
  retiring, and the round-2 comparison's "control arm" framing would need
  correcting a second time.

**The reflowed fixture measures how brittle it is.** Seam 6 flipping to COVERED
on a plan whose coverage did not change is a false negative produced purely by
prose layout — the failure mode a gate must never have, because it goes *green*
on something broken. If it flips, the robot's seam-6 check is measuring
sentence spacing, not coverage, and should be deleted rather than tuned.

A robot that passes the covered fixture but fails the reflowed one is still
usable, narrowly: keep it pinned to an input whose prose nobody edits, and
never trust its seam-6 line on its own.
