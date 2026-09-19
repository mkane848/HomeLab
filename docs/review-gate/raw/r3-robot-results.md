# Robot negative control — results (2026-09-19)

**The robot discriminates.** Given a plan where seams 5 and 6 are genuinely
covered it returns FIRST-RUN-SAFE; given the original it returns RED-MARK. Its
agreement with the human audit in round 2 was therefore not the artefact of a
detector that can only ever say "bad."

Protocol and predictions: [`../r3-robot-control.md`](../r3-robot-control.md).
Raw outputs: [`r3-robot/`](r3-robot/).

## Predicted vs actual

| Input | Predicted | Actual | |
|---|---|---|---|
| `r2-remeasure-input.md` | RED-MARK, 5+6 UNCOVERED | RED-MARK, 5+6 UNCOVERED | ✓ |
| `r3-robot-fixture-covered.md` | FIRST-RUN-SAFE, all six COVERED | FIRST-RUN-SAFE, all six COVERED | ✓ |
| `r3-robot-fixture-reflowed.md` | RED-MARK, **seam 6 flipped to COVERED** | RED-MARK, **seam 6 still UNCOVERED** | ✗ |

Two of three. The baseline reproducing matters most: it confirms the robot has
not drifted since `0f76bb7`, so the other two runs mean something.

The covered fixture moved every cell it was supposed to move and nothing else —
seam 5 to COVERED on `commanders arg: [[chooser, background]]`, seam 6 to
COVERED on `test-level banned-commander=True` — while seams 1–4 stayed put.
That is the behaviour a regression gate needs.

## The failed prediction was an error in the analysis, not in the robot

The reflow fixture was built to flip seam 6 by moving "commanders" and "banned"
closer together in Section 2. It didn't, and the reason is a defect in how this
repo has been reasoning about the robot:

**PowerShell's `-match` has no DOTALL.** `.` does not cross a newline. The
seam-6 contract alternative
(`commanders.{0,160}(legality_commander|banned)|…`) can therefore only ever
match when both words sit on **one line**. The fixture put them on adjacent
lines, so the alternative could not fire regardless of distance.

The prediction came from a Python simulation that passed `re.DOTALL`. Under
DOTALL the match spans the line break and returns True; without it, False. The
simulation was faithful enough to reproduce `r2-robot-output.md` exactly on the
original input — which is why the error survived — but it was not faithful on
this one point.

Two consequences, both now corrected in `r2-comparison.md`:

1. **The "roughly ten characters" margin claim is void.** It was computed under
   the same DOTALL assumption. The real constraint on seam 6's contract check is
   same-line adjacency, not a character count.
2. **"Its ability to discriminate is untested" is no longer true** — it is
   tested, and it passes.

## What is still unknown

**Seam 6's brittleness has not actually been measured.** The fixture that was
supposed to measure it tested something else. A valid probe needs "commanders"
and a ban token on a *single* line of Section 2, without adding any real check.
Worth doing before the robot is trusted on a plan whose contract prose differs
in layout from this one — but it is a narrower question than the one this round
set out to answer, and the answer to that one is good.

**Nothing here changes the reviewer-seat conclusion.** That rests on the 18 runs
in `r3-results.md`. This round only establishes what the robot is good for.

## Standing

The robot is sound as a **regression gate on this plan**: it goes green when the
coverage is really there and red when it is not, deterministically and in
milliseconds. It is still a set of literal string matches written for one
document, so it remains unsuitable as a general reviewer, and its seam-3 check
still passes on the absence of a token.
