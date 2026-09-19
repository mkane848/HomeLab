# Review-gate rounding: comparison across all arms (2026-09-19)

One fixed input (`docs/review-gate/raw/r2-remeasure-input.md`), one prompt
controller (`docs/review-gate/reviewer.md`), four decisions on the same six
seams. Ground truth (from `docs/review-gate/testing.md` + the PR review that
started this): a legal Background pair is rejected by the PR's
`eligibility = commanders.every(is_commander_eligible)` (seam 5), and the
route never directly ban-checks a resolved named commander (seam 6). Both are
catchable entirely from the pasted material. The key file was never pasted to
any arm.

## Comparison table

| Arm | Verdict | Seams 1–4 (classic) | Seam 5 (Background) | Seam 6 (commander ban) | Notes |
|---|---|---|---|---|---|
| `deepseek-r1:14b` (run 1, earlier) | FIRST-RUN-SAFE | 4/4 ✓ | ✗ | ✗ | directed checklist ignored; reasoning.txt:28 asserts "no missed branches" |
| `qwen3.5:9b` draw 1 (leg 1) | FIRST-RUN-SAFE | 4/4 ✓ | ✗ (stamped COVERED) | ✗ (stamped COVERED, fabricated "plan ensures named commanders are checked against ban lists") | rubber-stamp + confabulation |
| `qwen3.5:9b` draw 2 (leg 1) | FIRST-RUN-SAFE | 4/4 ✓ | ✗ | ✗ | same |
| `qwen3.5:9b` draw 3 (leg 1) | **CAUTION** | 4/4 ✓ | ✓ flagged (test-veracity: "green on broken code") | ✓ flagged ("plan should include a test: 'A banned commander in commanderNames fails validation'") | correct diagnosis of both deciding seams — the flaky draw |
| **Majority-of-3 (qwen3.5:9b)** | **FIRST-RUN-SAFE** | 4/4 ✓ | 1/3 flagged | 1/3 flagged | majority says SAFE on broken code — the hedge fails on this draw set |
| `qwen3:14b` (run 3, earlier) | FIRST-RUN-SAFE | 4/4 ✓ | ✗ | ✗ (stamped COVERED citing the Partner-pair test — non-sequitur) | same class as R1 |
| **Deterministic checker robot** (leg 2, `seam-checker.ps1`) | **RED-MARK** | 4/4 ✓ | ✓ UNCOVERED | ✓ UNCOVERED | no model, no variance, ~instant; matched ground truth exactly |

## Reading the data

- **Every LLM arm passes the classic bar (4/4) and fails the deciding seams
  unless variance happens to cooperate** — draw 3 was the only LLM draw across
  the whole round (9 LLM runs this session) that flagged both seams. All the
  FIRST-RUN-SAFE arms reached that verdict by not opening the test inputs:
  they asserted the Background test "reaches the branch" or that named
  commanders are "checked against ban lists" on zero evidence.
- **Majority-of-3 did not save qwen3.5:9b.** The two SAFE draws out-voted the
  one CAUTION draw. Contracting false-positive odds that way only works when
  the bad lane is a minority; here it was 2/3. Note the caveat of small n.
- **The robot reproduces the human's audit exactly, deterministically, in
  ~0s, with zero model risk.** It is the control arm: the job at this level of
  abstraction is mechanical. Its three implementation attempts (seam-6 word
  matching) are a good illustration of *why* determinism is a feature here —
  each bug was found and fixed, unlike an LLM's silent rubber-stamp.
- qwen3.5:9b's draw 3 is the first LLM output that identified the *right* hole
  in the right test (the `makeCard` default means the pair can never reach the
  branch), though it wobbled between interpretations before landing. That is:
  the model can think this through — it just doesn't reliably *choose* to.

## Live (unresolved) decisions for the human

1. **Seat policy:** demote the LLM reviewer to drafting with the robot as the
   verdict gate (deterministic RED-MARK/CLEAR), vs. keep an LLM reviewer seat
   (stochastic, DRAW-3 showed both lanes), vs. a hosted draw for leg 3
   (parked — needs a key).
2. **Registry:** `reviewer.md` currently defines the seat as `deepseek-r1:14b`,
   which is now known-failing; no re-pin should happen until this comparison is
   reviewed.
3. **Hosted leg** never ran. If one is wanted, supply an endpoint + key.

Per the session plan, **no config re-pins or seat changes were made** — this
document is the data dump for human review before any further change.

## Raw outputs
- LLM draws (verbatim): `r2-compare-draw{1,2,3}-qwen35.md`
- Robot: `r2-robot-output.md`; tool: `seam-checker.ps1`
- Earlier graded runs: `r2-remeasure-run{1,2,3}-*.md` (R1, qwen3.5, qwen3:14b)
- All 9 LLM draws' raw JSON/content also in
  `C:\Users\<username>\AppData\Local\Temp\opencode\r2-rem\` (`response-*.json`,
  `content-*.txt`).