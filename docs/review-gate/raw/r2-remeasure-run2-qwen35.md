# Review-gate re-measure run 2 (2026-09-19) — qwen3.5:9b

Candidate run against the same fixed input (`docs/review-gate/raw/r2-remeasure-input.md`)
and prompt controller (`docs/review-gate/reviewer.md`). Key file never pasted.

## Runs this session

| Run | Config | Result |
|---|---|---|
| 2a | think ON (default), `/v1/chat/completions`, `max_tokens` 8192 | `finish_reason: length` at exactly 8192 completion tokens — the whole budget burned on the `reasoning` block; content empty (2 chars). **Unusable in default think mode at this budget.** This is the AGENTS.md "reasoning models + small max_tokens → EMPTY content" trap. |
| 2b | think OFF (`think:false` via `/api/chat`, `num_predict` 8192) — checklist before the seam-6 line was added | **RED-MARK.** Seams 1–4 COVERED; seam 5 FLAGGED (Background test passes only the chooser ⇒ could be green on broken code); seam 6 not mentioned. |
| 2c | think OFF, same prompt + the NEW generic checklist seam: "named-commander inputs get the full legality surface…" | **FIRST-RUN-SAFE (wrong).** Seam 5 stamped COVERED ("these inputs actually reach the specific branches" — false); seam 6 stamped COVERED by **fabricating a plan assertion** the contract never makes; TEST VERACITY "VERIFIED". Textbook unsupported-claim FAIL against the prompt's own opening rule ("a claim of yours that needs a file you cannot see is an unsupported-claim FAIL"). |

Raw outputs: `C:\Users\<username>\AppData\Local\Temp\opencode\r2-rem\`
(`response-qwen35.json`, `-nothink.json`, `-nothink2.json` + content extracts).

## Grade

- **2b is the only qwen3.5:9b result that answers correctly:** 5/6 seams
  (seams 1–4 ✓, seam 5 ✓ via TEST VERACITY, seam 6 ✗), correct RED-MARK verdict
  direction. Its stated mechanism for the Background flaw is imprecise (claims
  the background card isn't injected, when the inventory *does* pass
  `backgrounds: [background]`; the true wound is that the **pair is never in
  `commanders`**, so the eligibility path can't exercise the rejection). The
  *detection* is right regardless.
- **2c is a clean FAIL** — same model, microseconds later, turns the checklist
  into an invitation to confabulate coverage. Same failure class as R1 run 1
  and run 1's original miss: assert COVERED, don't verify.
- **Net: qwen3.5:9b is inconsistent.** It can find the deciding seam, then
  escape it on the identical material when nudged. That run-to-run flip
  (RED-MARK ⇄ FIRST-RUN-SAFE on near-identical input) fails the purpose of the
  seat — the review gate exists because a false-positive FIRST-RUN-SAFE ships
  a broken PR. Under the registered decision rule (flags seams 5–6 **and**
  calls RED-MARK), **qwen3.5:9b does not take the seat.**
- Also learned: **adding checklist seams did not help**; it invited
  rubber-stamping. The bottleneck is verification discipline (actually reading
  the argument lists), not enumeration.

## Options forward (selecting one is the user's call)

1. **Run `qwen3:14b` next** (think OFF) on the same material — one more
   candidate while the cost is a 90-second run.
2. **Majority-of-3 policy for qwen3.5:9b** — three draws, verdict = most
   common; contract the false-positive odds. Costs ~3× latency per review.
3. **Accept the gate needs determinism** — build the seam checks as the
   reviewer *plus* a scripted checklist robot; human reconciles. Local LLMs
   get a seat only for prose/draft, never the verdict.
4. Stop the local-seat hunt (three failed candidates), route the review gate
   to the strongest hosted model and re-pin (`lmstudio-vscode.md` seats table).