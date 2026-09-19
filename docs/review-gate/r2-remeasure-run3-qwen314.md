# Review-gate re-measure run 3 (2026-09-19) — qwen3:14b

Candidate draw (Option 1 from run 2's "Options forward"). Same fixed input
(`docs/review-gate/r2-remeasure-input.md`), same prompt controller
(`docs/review-gate/reviewer.md`, including the named-commander-legality seam
added for run 2c). Key file never pasted.

**Run record:** `qwen3:14b`, `think:false` via `/api/chat`, `num_predict` 8192,
stream off. `prompt_eval_count` 3132, `eval_count` 1215, `done_reason: stop`
(complete, not truncated). Raw output:
`C:\Users\<username>\AppData\Local\Temp\opencode\r2-rem\response-qwen314-nothink.json`
+ `content-qwen314-nothink.txt`.

## Verdict: FAILED — qwen3:14b does not take the reviewer seat

| Seam | Ground truth | Reviewer's call | Grade |
|---|---|---|---|
| 1 JSON decode | covered | COVERED (decode test cited) | ✓ |
| 2 size counting | covered | COVERED (banned/notFound slot tests cited) | ✓ |
| 3 strict typing | covered | COVERED | ✓ |
| 4 eligibility/pairing basis | covered | COVERED | ✓ |
| 5 Background eligibility bug | uncovered | COVERED — cites the Background test, never notes the pair is absent from `commanders` | ✗ |
| 6 direct ban-list check | uncovered | COVERED — **evidence given is the "legal Partner pair" test**, which has nothing to do with a ban list (non-sequitur proof) | ✗ |
| TEST VERACITY | holds seam 5 | "COVERED — tests are not green on broken code": asserted, never demonstrated, false | ✗ |
| Verdict | RED-MARK | **FIRST-RUN-SAFE** | ✗ |

Same failure class as R1 run 1 and qwen3.5 run 2c: stamp COVERED, fabricate or
misattribute evidence, never open the argument lists.

## Seat survey status (all four projected local candidates exhausted)

| Candidate | Result |
|---|---|
| `deepseek-r1:14b` | FIRST-RUN-SAFE on broken code (4/6) — off seat |
| `qwen3.5:9b` | one correct RED-MARK (5/6), then flipped to confabulated FIRST-RUN-SAFE — unreliable, off seat |
| `qwen3:14b` | FIRST-RUN-SAFE, seams 5–6 stamped COVERED with non-sequitur evidence (4/6) — off seat |
| `devstral:24b` / `qwen2.5-coder:14b` | not worth a draw at this point — same family traits as the three failures (checklist rubber-stamping), at higher inference cost per token; the bottleneck is verification discipline, and none of three families showed it |

Every attempt to seat a *reliable* red-marking reviewer on the 16 GB box has
failed at the same seam: models confirm coverage claims without checking test
inputs. The two live policy options from the run-2 record therefore stand:
majority-of-3 on qwen3.5:9b (the only seat that ever emitted a RED-MARK),
or a deterministic scripted seam-checker with the LLM demoted to drafting.