# Review-gate round 3 — results (2026-09-19)

**The hypothesis is not supported.** Forcing a per-test ledger raised output
length exactly as predicted and did not convert misses into hits. Across 18
runs, the deciding seams were caught by **1 run in 9** under the treatment and
**0 in 9** under the control — all movement confined to one model.

This is a negative result, and it **strengthens** the round-2 conclusion that
the correction in `r2-comparison.md` called weak. That conclusion now rests on
18 runs with recorded sampling parameters and a provably constant prompt,
rather than n=1 with none. The round-2 *scoring* was still wrong; its
*conclusion* survives better evidence.

Protocol: [`../r3-protocol.md`](../r3-protocol.md). Raw runs: [`r3/`](r3/).

---

## What was run

18 runs — 3 models × 2 arms × 3 seeds — in 14.4 minutes of wall clock. Every
run finished `done_reason: stop`; nothing truncated.

The things round 2 could not show, shown here:

- **Prompt constancy is provable.** All 9 Arm A runs carry prompt hash
  `48d960af65f2fd96`; all 9 Arm B runs carry `8b8ffc180b391a84`. Round 2
  asserted "one prompt controller" and was wrong (the seam-6 bullet landed
  mid-round).
- **Sampling is recorded**: seed 1/2/3, temperature 0.8, `num_ctx` 16384,
  `num_predict` 12288 on every row. Round 2 recorded none, so none of its runs
  were reproducible.
- **Every run is in the repo** — JSON and extracted content both. Five of round
  2's eight runs are still stranded in `%TEMP%`.
- No prompt file was modified during the round (`git log` on `reviewer.md`,
  `r3-ledger-clause.md` and the input shows nothing after the protocol commit).
- **Ledger compliance was total**: 9/9 Arm B runs produced the table, 11–24
  rows each. The treatment was administered, not ignored.

## The grade

Ground truth unchanged: seams 1–4 covered, seams 5 and 6 uncovered.
Per the repaired rule (`r3-protocol.md`), CAUTION and RED-MARK both count as
correctly declining; FIRST-RUN-SAFE is the only failing verdict.

| Run | Verdict | Seam 5 | Seam 6 | Bonus (99/98) |
|---|---|---|---|---|
| `deepseek-r1:14b` A d1–d3 | FIRST-RUN-SAFE ×3 | ✗ ✗ ✗ | ✗ ✗ ✗ | ✗ |
| `deepseek-r1:14b` B d1–d3 | FIRST-RUN-SAFE ×3 | ✗ ✗ ✗ | ✗ ✗ ✗ | ✗ |
| `qwen3:14b` A d1–d3 | FIRST-RUN-SAFE ×3 | ✗ ✗ ✗ | ✗ ✗ ✗ | ✗ |
| `qwen3:14b` B d1–d3 | FIRST-RUN-SAFE ×3 | ✗ ✗ ✗ | ✗ ✗ ✗ | ✗ |
| `qwen3.5:9b` A d1 | RED-MARK | ✗ | ✓ **+2 false positives** | ✗ |
| `qwen3.5:9b` A d2, d3 | FIRST-RUN-SAFE ×2 | ✗ ✗ | ✗ ✗ | ✗ |
| `qwen3.5:9b` B d1 | CAUTION | ✗ | ✗ | ✗ |
| **`qwen3.5:9b` B d2** | **RED-MARK** | **✓** | **✓** | **✓** |
| `qwen3.5:9b` B d3 | FIRST-RUN-SAFE | ✗ | ✗ | ✗ |

| | Arm A | Arm B |
|---|---|---|
| Declined to pass | 1/9 | 2/9 |
| Both deciding seams | **0/9** | **1/9** |
| Seam 6 alone | 1/9 (with 2 false positives) | 1/9 |
| Bonus defect | 0/9 | 1/9 |

## The manipulation worked; the effect did not follow

Median `eval_count` moved **1229 → 1770**, straddling the ~1250/~1750 threshold
the hypothesis was built on. It rose for every model:

| model | Arm A median | Arm B median |
|---|---|---|
| `deepseek-r1:14b` | 1097 | 1770 |
| `qwen3:14b` | 1100 | 1643 |
| `qwen3.5:9b` | 1755 | 2396 |

Median content length rose too, 4731 → 6612 characters. The predicted mechanism
was achieved in full and the predicted outcome did not materialise. That is what
makes this a clean falsification rather than a failed manipulation.

## Why length is not the lever

Three findings, each independently sufficient:

**1. Correct transcription, wrong inference.** `deepseek-r1_14b-armB-d2.txt:16`
transcribes the decisive fact accurately:

> `| 10 | Commander unit legality | - commanders: [chooser] (partner_ability: 'choose_background'), backgrounds: [background] | pairingLegal = true | YES |`

`commanders: [chooser]` is exactly what seam 5 turns on. The model wrote it
down, then answered YES — the branch matches the name — and passed the plan.
Transcription was never the bottleneck. Reasoning from the transcription is.

**2. The longest run in the round was a control run that still missed seam 5.**
`qwen3_5_9b-armA-d1` emitted 9272 tokens / 35.7k characters — 5× the round
median — and returned RED-MARK. But it explicitly cleared the Background test
(`:367`: "passes a background, so it is **VERACITY PASS**"), and reached its
verdict by declaring JSON decoding (`:362`) and whole-dataset counting (`:363`)
UNCOVERED, both of which are ground-truth covered. Long, declining, and wrong
on three of four counts.

**3. `qwen3:14b` was entirely unmoved.** 6/6 FIRST-RUN-SAFE, 6/6 "COVERED" on
seam 6, with complete ledgers in Arm B. Its seam-6 evidence at
`qwen3_14b-armB-d1.txt:71` cites the test *"a card that is not
commander-eligible cannot be named commander"* — an eligibility test, not a
ban-list test. Same non-sequitur class as round 2's run 3, which cited the
Partner-pair test for the same seam. The ledger did not touch it.

## What did move

`qwen3_5_9b-armB-d2` is **the only fully correct review in the two-round
corpus**. It flagged seam 6 (`:83`), flagged seam 5 via test-veracity (`:86`),
and — unprompted — caught the instrument's own planted-by-accident defect
(`:85`):

> `| TEST VERACITY (Test #2: "99 cards" vs 98 arg) | **FAIL** | Arguments construct 98 cards, name says 99. |`

Nothing in the key, the checklist or the input points at that mismatch. No arm
in round 2 caught it. It was found by exactly the question the ledger forces —
*does the reached branch match the name?* — which is evidence the mechanism can
work. It worked once in nine.

Its seam-5 mechanism is imprecise in the familiar way ("arguments omit the
background card from the pasted list"), the same imprecision credited in round
2's run 2b and draw 2. Detection credited, mechanism noted.

## New finding: declining has a false-positive cost

Neither prior round measured this. Of the three non-passing verdicts here:

- `qwen3.5 B d2` — correct, on correct reasoning.
- `qwen3.5 A d1` — correct conclusion, two false positives (seams 1 and 2
  declared uncovered when both are covered).
- `qwen3.5 B d1` — **CAUTION triggered by seam 3**, the free point. Its summary
  asks the human to "verify that the implementation ... does not rely on `any`"
  — a seam the input never mentions. It also states "The Test Ledger confirms
  the inputs in the tests correctly trigger the named branches," i.e. the
  ledger actively reassured it.

So 1 of 3 declines was sound. A gate that red-marks on phantom seams spends
human review time and erodes trust in the gate; round 2 only ever counted false
negatives. Any future seat rule needs both numbers.

## Instrument defects found in this round

- **`think:false` was not honoured by `deepseek-r1:14b`.** All six of its runs
  returned a populated `thinking` field (2.3k–6.0k characters) alongside
  content, and `eval_count` counts those tokens. Its length figures therefore
  mix hidden reasoning with visible output and are not comparable to the other
  two models'. `deepseek-r1_14b-armA-d1` is the clearest case: 1097 eval tokens,
  4693 characters of `thinking`, and **251 characters of content**. The runner
  preserves `thinking` in the JSON but writes only `content` to the `.txt`, so
  nothing is lost — but any length claim about R1 in round 2 or round 3 needs
  this caveat. Round 2's records state think-off was in effect for R1; that
  should be re-checked.
- **Arm A is not byte-identical to round 2.** Its `prompt_eval_count`
  (3104/3116/3193) runs 16–18 tokens below round 2's recorded 3132 and 3211.
  Within 0.5%, and irrelevant to an A/B where both arms share a construction,
  but the control is a faithful reconstruction rather than the original string.

## What this settles

- **The reviewer seat does not yield to prompt shape.** Three families, two
  prompt designs, 18 runs, one correct review. The bottleneck is verification
  *reasoning*, not enumeration (round 2's finding) and not transcription
  (round 3's). Prompt engineering is not the remaining lever.
- **The fleet reviewer-gap decision is no longer blocked on the "it might be
  the prompt" objection.** It is also not a VRAM problem: a larger card does not
  buy verification reasoning. `glm4:9b` is a weaker candidate than three models
  that have now failed across 18 runs, and buying a third 16 GB node to fit a
  bigger reviewer does not address the measured failure.
- **`qwen3.5:9b` remains the only local model that has ever done the job** —
  now roughly 1-in-3 across both rounds. That is a drafting aid, not a gate.
  It should never issue the verdict alone.

## Not run

- **Arm C** (the de-leaked prompt, stripping the two checklist bullets that
  telegraph seam 5). Still the open question of whether seam 5 is ever derived
  or only echoed — and given that models with the hint still miss it 17 times
  in 18, the answer is now less interesting than it was.
- **A hosted arm.** Untried in any round. It is the only untested option that
  could plausibly change the seat answer.
- **`ollama --version` was not reported** with these runs. Every tool-call and
  VRAM measurement in these docs is taken against 0.34.0; template changes
  between versions move results. Unconfirmed for this round.
- Whether `r3-runner.ps1` parsed clean or needed syntax repair was not
  reported. Nothing was committed against it, so the runner in the tree is
  presumed to be the one that produced these results — unverified.
