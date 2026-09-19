# Review-gate rounding: comparison across all arms (2026-09-19)

> **CORRECTION (2026-09-19, post-review).** The first version of this table
> mis-scored the `qwen3.5:9b` draw-2 arm and drew its headline conclusion from
> that error. Draw 2 was recorded as `FIRST-RUN-SAFE | seam 5 ✗ | seam 6 ✗`;
> the committed raw file `r2-compare-draw2-qwen35.md` actually ends
> `**Verdict:** CAUTION` (draw2:67) and flags **both** deciding seams
> (seam 5 at draw2:17, seam 6 at draw2:47/:58/:69). All three cells were wrong.
>
> Because the majority-of-3 row was computed from those cells, it was also
> wrong: the majority verdict is **CAUTION**, not FIRST-RUN-SAFE, and both
> deciding seams were flagged by **2 of 3** draws, not 1 of 3. The original
> claim "the hedge fails on this draw set" is therefore not supported by the
> draws committed alongside it — on this draw set the hedge worked.
>
> A second scoring error: the `deepseek-r1:14b` arm was graded ✗ on seam 6, but
> that arm ran **before** the seam-6 checklist line existed. `git show 95a8488
> -- docs/review-gate/reviewer.md` adds that bullet; run 1 (`a0abad7`) and run
> 2b predate it. R1 was never asked about seam 6. The opening line "one prompt
> controller" was false for that arm.
>
> Original (withdrawn) values are preserved in "Superseded scoring" at the
> bottom. Conclusions that depended on them are rewritten below; nothing else
> in the round was re-run.

One fixed input (`docs/review-gate/raw/r2-remeasure-input.md`) and **two
successive versions** of the prompt controller (`docs/review-gate/reviewer.md`
— the seam-6 bullet was added mid-round at `95a8488`), scored against the same
six seams. Ground truth: a legal Background pair is rejected by the PR's
`eligibility = commanders.every(is_commander_eligible)` (seam 5), and the route
never directly ban-checks a resolved named commander (seam 6). Seam 5 traces to
`docs/review-gate/testing.md` + the PR review that started this; **seam 6
traces to the grader key alone** — `testing.md` contains no ban-list material
(grep: zero occurrences of `ban`/`banned`/`legality_commander`). The key file
was never pasted to any arm.

## Comparison table

| Arm | Prompt version | Verdict | Seams 1–4 (classic) | Seam 5 (Background) | Seam 6 (commander ban) | Notes |
|---|---|---|---|---|---|---|
| `deepseek-r1:14b` (run 1, earlier) | pre-seam-6 | FIRST-RUN-SAFE | 4/4 ✓ | ✗ | **n/a — not asked** | directed checklist ignored; reasoning.txt:28 asserts "no missed branches". Seam 6 was not in its checklist; scoring it ✗ was an error |
| `qwen3.5:9b` draw 1 | current | FIRST-RUN-SAFE | 4/4 ✓ | ✗ (stamped COVERED) | ✗ (stamped COVERED, fabricated "plan ensures named commanders are checked against ban lists") | rubber-stamp + confabulation; also twice misattributes evidence to `docs/handoff.md` |
| `qwen3.5:9b` draw 2 | current | **CAUTION** | 4/4 ✓ | **✓ flagged** — "the plan provides *only* the chooser in the `commanders` input" (draw2:17) | **✓ flagged** — "Status: **UNCOVERED**" (draw2:47, :58, :69) | correct on both deciding seams. Mechanism half-right: the "never passes the Background card" clause is wrong (the inventory *does* pass `backgrounds: [background]`) — same imprecision credited in run 2b |
| `qwen3.5:9b` draw 3 | current | **CAUTION** | 4/4 ✓ | ✓ flagged (test-veracity: "green on broken code") | ✓ flagged ("plan should include a test: 'A banned commander in commanderNames fails validation'") | correct on both, on a **different** mechanism than the key's — it explicitly rejects the solo-chooser reading (draw3:48) and lands on the `makeCard` eligibility default. Visibly reverses itself several times before landing |
| **Majority-of-3 (qwen3.5:9b)** | current | **CAUTION** | 4/4 ✓ | **2/3 flagged** | **2/3 flagged** | majority lands on the correct verdict direction; the rubber-stamp lane was the minority. Small n — one draw set |
| `qwen3:14b` (run 3, earlier) | current | FIRST-RUN-SAFE | 4/4 ✓ | ✗ | ✗ (stamped COVERED citing the Partner-pair test — non-sequitur) | same class as draw 1 |
| **Deterministic checker robot** (leg 2, `seam-checker.ps1`) | n/a | **RED-MARK** | 4/4 ✓ | ✓ UNCOVERED | ✓ UNCOVERED | no model, no variance, ~instant — but see the caveat below: it is literal-string matching written against this one input |

**Caveat on "4/4 classic".** Seam 3 (strict typing) is a free point for every
arm including the robot. The reviewer input never mentions typing, `any`, or
type strictness at all — the only three occurrences of "any" in the file are
ordinary English. Every arm scored it COVERED on the absence of a string. The
real classic bar cleared here is 3/4.

## Reading the data

- **The deciding seams split the arms, and the split is not what the first
  version of this table said.** Of the five LLM draws on the current prompt,
  two (draw 2, draw 3) flagged both deciding seams and returned CAUTION; three
  (draw 1, run 2c, run 3 `qwen3:14b`) stamped them COVERED and returned
  FIRST-RUN-SAFE. The FIRST-RUN-SAFE arms reached that verdict by not opening
  the test inputs: they asserted the Background test "reaches the branch" or
  that named commanders are "checked against ban lists" on zero evidence.
- **Majority-of-3 landed correctly on this draw set.** Two CAUTION draws
  out-voted one FIRST-RUN-SAFE. Contracting false-positive odds that way works
  when the bad lane is a minority; here it was 1/3. That is one draw set of
  three — enough to withdraw the previous conclusion, not enough to seat a
  model on. The obvious next measurement is more draws, not a different family.
- **Verdict length separates the hits from the misses better than model family
  does.** Across the five runs with a recorded completion count:
  run 1 R1 (1145 tokens) 0/2 deciding seams; draw 1 (1205) 0/2; run 3
  `qwen3:14b` (1215) 0/2; draw 2 (1759) **2/2**; draw 3 (5334) **2/2**. Every
  run under ~1250 tokens missed both; every run over ~1750 caught both, across
  three model families. n=5 and confounded with model and prompt version, so
  this is a hypothesis — but it is consistent with the round's other finding
  (the bottleneck is verification discipline, not enumeration), and a model
  emitting 1200 tokens cannot have walked each test's argument list. Worth one
  controlled measurement before any further seat or hardware decision.
- **The robot is a regression gate, not a control arm.** Every check is a
  verbatim string from the one input it was written against (seams 1, 2 and 4
  match exact test-title sentences; seam 5 reduces to "does the `commanders`
  argument contain a comma"; seam 6 is word matching plus a proximity regex
  that clears its threshold by roughly ten characters). Seam 3 scores COVERED
  on the *absence* of a token, so an empty file would pass it, and since
  RED-MARK fires on any single UNCOVERED, **RED-MARK is the robot's default
  output for essentially any document**. It reproduces the human audit on this
  input because the audit was compiled into it. It has never been run against a
  second input, and no negative control (a plan that genuinely covers seams
  5–6) has been tried, so its ability to *discriminate* is untested. Useful to
  keep this plan's coverage from regressing; not evidence that the job is
  mechanical.
- **Both qwen3.5 draws that caught seam 5 got the mechanism partly wrong**, in
  opposite directions — draw 2 mis-states which array the Background is missing
  from, draw 3 rejects the solo-chooser reading entirely and blames the
  `makeCard` default. The detection is right in both; the causal story is not.
  If the gate's output feeds a fix, the mechanism matters, and neither draw
  would have produced the correct patch unaided.

## Known limits of this round

- **The prompt changed mid-round.** Only draws 1–3, run 2c and run 3 share a
  prompt. R1 and run 2b ran on the pre-seam-6 checklist. Cross-arm comparison
  on seam 6 is only valid within the current-prompt group.
- **Sample sizes.** `deepseek-r1:14b` n=1. `qwen3:14b` n=1. `qwen3.5:9b` n=6
  attempts / 5 usable, across two prompt versions. `devstral:24b` and
  `qwen2.5-coder:14b` were **never run** — so "survey of four candidates
  exhausted" (`lmstudio-vscode.md`) overstates what was measured.
- **No sampling parameters were recorded** for any run — no temperature, top_p
  or seed anywhere in this corpus. Independence of the three draws is inferred
  from divergent `eval_count` (1205 / 1759 / 5334) against an identical
  `prompt_eval_count` (3211), not established.
- **Five of eight runs are unauditable from this repository** — run 1, 2a, 2b,
  2c and run 3 have raw output only under a Windows `%TEMP%` path. Only draws
  1–3 and the robot have verbatim outputs committed.
- **Grading standard was applied inconsistently.** The registered rule (key:20)
  requires flagging seams 5–6 *and* calling RED-MARK. Draws 2 and 3 both
  returned CAUTION — which `reviewer.md` defines as the correct verdict for
  "implementation seams uncovered but plan otherwise sound" — and the first
  version of this table counted draw 3's CAUTION as a success while counting
  draw 2's identical CAUTION as a failure. The rule needs to say whether
  CAUTION satisfies it before the next round is graded.
- **The instrument carries an unflagged defect of exactly the kind the method
  exists to catch.** `r2-remeasure-input.md:127` titles a test "99 cards is
  invalid" over a body reading "commander + 97 Plains (98 total) ... asserts
  `deckSize.total = 98`". Name and body disagree. No arm caught it — not the
  LLMs, not the robot, not the key.

## Live (unresolved) decisions for the human

1. **Seat policy — reopened by this correction.** The previous framing (demote
   the LLM reviewer to drafting, robot as the verdict gate) rested on
   majority-of-3 having failed and the robot having independently reproduced
   the audit. Neither holds as stated. The live options are now: (a) measure
   the verdict-length lever on the three "failed" models before changing seats
   at all; (b) more draws on `qwen3.5:9b` to see whether majority-of-3 holds up
   past one draw set; (c) robot as a regression gate *alongside* an LLM
   reviewer rather than in place of one; (d) a hosted draw for leg 3 (parked —
   needs a key).
2. **Registry:** `reviewer.md` still defines the seat as `deepseek-r1:14b`. It
   remains un-repinned — and R1's disqualification is now weaker than recorded,
   since it was scored on a seam it was never asked about. A clean re-run of R1
   on the current prompt would settle it in one ~90-second draw.
3. **Hosted leg** never ran. If one is wanted, supply an endpoint + key.

Per the session plan, **no config re-pins or seat changes were made** — this
document is the data dump for human review before any further change.

## Superseded scoring (withdrawn 2026-09-19)

Kept so the error stays in the record. The original table read:

| Arm | Verdict | Seam 5 | Seam 6 | Note as published |
|---|---|---|---|---|
| `deepseek-r1:14b` (run 1) | FIRST-RUN-SAFE | ✗ | ✗ | scored ✗ on a seam its prompt never contained |
| `qwen3.5:9b` draw 2 | FIRST-RUN-SAFE | ✗ | ✗ | "same" — all three cells wrong; actual verdict CAUTION, both seams flagged |
| **Majority-of-3** | **FIRST-RUN-SAFE** | 1/3 flagged | 1/3 flagged | "majority says SAFE on broken code — the hedge fails on this draw set" |

And the two conclusions drawn from them, both withdrawn:

> draw 3 was the only LLM draw across the whole round (9 LLM runs this session)
> that flagged both seams

Draw 2 flagged both, in the same commit. The count "9 LLM runs" is also
unsupported — eight are documented (run 1, 2a, 2b, 2c, run 3, draws 1–3).

> **Majority-of-3 did not save qwen3.5:9b.** The two SAFE draws out-voted the
> one CAUTION draw ... here it was 2/3.

Inverted: two CAUTION draws out-voted one SAFE draw; the bad lane was 1/3.

> qwen3.5:9b's draw 3 is the first LLM output that identified the *right* hole
> in the right test (the `makeCard` default means the pair can never reach the
> branch)

Draw 2 preceded it and stated the key's own mechanism. The parenthetical also
fuses draw 3's mechanism with the key's wording; draw 3 explicitly rejects the
key's reading at draw3:48.

## Raw outputs
- LLM draws (verbatim): `r2-compare-draw{1,2,3}-qwen35.md`
- Robot: `r2-robot-output.md`; tool: `seam-checker.ps1`
- Earlier graded runs: `r2-remeasure-run{1,2,3}-*.md` (R1, qwen3.5, qwen3:14b)
- Raw JSON/content for the eight runs also in
  `C:\Users\<username>\AppData\Local\Temp\opencode\r2-rem\` (`response-*.json`,
  `content-*.txt`) — outside the repo, so five of the eight are not auditable
  from here.
