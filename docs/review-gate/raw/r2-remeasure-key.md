# Review-gate re-measure — run 2 grader key (DO NOT PASTE TO THE REVIEWER)

Human-only answer sheet for `r2-remeasure-input.md`. The reviewer must arrive
at these findings **de novo** from the evidence + contract + test inventory in
the input file. Pasting any of this invalidates the metric.

## Known seams (ground truth, from the arbiter's corrections + the 2026-09-19
PR review — documented in `docs/lmstudio-vscode.md` and `docs/review-gate/testing.md`)

| # | Seam | Where it bites | Status in the PR (ground truth) | What a passing review says |
|---|---|---|---|---|
| 1 | JSON-string `color_identity` decoded **before** the rules consume it (`parseJsonArray`) | iterating a JSON string's characters instead of its colors | covered — unit test asserts the decode | COVERED (evidence = the decode test) |
| 2 | Deck size counts the **whole pasted deck**: banned + notFound slots included | telling a player "add a card" when the real fix is swapping one | covered | COVERED |
| 3 | Strict typing — no `any`-shaped escapes | silent type drift | covered | COVERED |
| 4 | Commander eligibility + pairing via `is_commander_eligible` + `buildCommanderUnits` | Sol Ring as commander; two unrelated legendaries | covered for solo + Partner cases | COVERED, **with a qualification** (see 5) |
| 5 | **Background-pairing eligibility bug (UNCOVERED)** | `eligible = commanders.every(c => c.is_commander_eligible === 1)` but the schema comment (given in Section 1) says a Background is *never* `is_commander_eligible` — so a fully legal pair named in `commanderNames` (Tevesh Szat, Doom of Fools + Boarding Party) is rejected. The "Background companion" unit test passes only the `chooser` in `commanders` and never the pair, so it never reaches the pairing/eligibility path | broken | RED-MARK / UNCOVERED — flagged via the eligibility/pairing seam + test-veracity |
| 6 | **Direct `legality_commander` check on named commanders (UNCOVERED)** | the route 404s on missing but never ban-checks a resolved commander; a banned commander is caught only if the pasted `list` happens to also contain it (Section 1 notes `partitionSubmittedCards` only sees the pasted list) | broken | UNCOVERED |

Target for this re-measure: seams 1–4 correctly classified (≥3/4, i.e. the
original 1/4 → ≥3/4) **and** seams 5–6 flagged. Seams 5–6 are the new
test-veracity/eligibility coverage the expanded checklist demands — flagging
them is the score that decides whether R1 keeps the seat.

## Scoring

- For each seam: reviewer said COVERED with evidence-checkable reasoning (or
  flagged UNCOVERED where that's true) → point.
- Contamination checks after the run: reviewer output must not restate the
  bug's mechanism as if handed to it ("the Background test only passes the
  chooser" must be *derived*, not quoted). If it quotes anything that only the
  key contains, discard the run.
- Record alongside this run: seam count, verdict length, wall-clock, `1/4 → ?`.
- Rerun the same input on any candidate reviewer seat for a same-input A/B;
  only the prompt/seat varies, never Section 1–3.