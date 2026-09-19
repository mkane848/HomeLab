# Review-gate round 3 — protocol

**Question.** Round 2 concluded that no local model can hold the reviewer seat.
That conclusion is weaker than it was recorded as (see the correction block in
`raw/r2-comparison.md`), and the round's own data contains an unexplored
pattern: across the five runs with a recorded completion count, every run under
~1250 tokens missed both deciding seams and every run over ~1750 caught both —
across three different model families.

| run | model | completion tokens | deciding seams |
|---|---|---|---|
| run 1 | `deepseek-r1:14b` | 1145 | 0/2 |
| draw 1 | `qwen3.5:9b` | 1205 | 0/2 |
| run 3 | `qwen3:14b` | 1215 | 0/2 |
| draw 2 | `qwen3.5:9b` | 1759 | **2/2** |
| draw 3 | `qwen3.5:9b` | 5334 | **2/2** |

That is suggestive, not a result: n=5, and length is confounded with model and
with prompt version. Round 3 tests it directly.

**Hypothesis.** The reviewer seat fails because models assert coverage without
transcribing what each test actually passes. If a prompt *requires* that
transcription before any verdict, the same models that failed round 2 will
catch the deciding seams. If they still fail, the seat conclusion stands on much
firmer ground than it does today, and the fleet decision can proceed.

**Why this matters before anything else.** The open fleet decision (third 16 GB
node vs. partial-offload R1 on node3 vs. `glm4:9b`) is currently framed as a
VRAM problem. If the bottleneck is prompt-shaped rather than capacity-shaped,
that decision changes shape entirely and the hardware spend may be unnecessary.

---

## Design

One variable. Two arms, same fixed input, same models, same sampling.

| | Arm A (control) | Arm B (treatment) |
|---|---|---|
| Input | `raw/r2-remeasure-input.md`, byte-identical to round 2 | same |
| Prompt | `reviewer.md` as-is | `reviewer.md` + the STEP 1 TEST LEDGER clause |
| Everything else | identical | identical |

The treatment clause (`r3-ledger-clause.md`) is a **process** requirement: it
forces a per-test table of *arguments the test constructs → branch those
arguments reach → does that match the name*, and forbids writing COVERED before
the table exists. It names no seam, no bug and no file. Higher token counts are
the expected side effect, not the instruction — `eval_count` is recorded to
confirm the clause actually produces them.

**Models:** `deepseek-r1:14b`, `qwen3:14b`, `qwen3.5:9b` — the three that
failed round 2. **Draws:** 3 per cell. 3 × 2 × 3 = **18 runs**, roughly 30–45
minutes.

### Fixed and recorded this time

Round 2 recorded no sampling parameters at all, so none of its runs are
reproducible. Round 3 pins and logs: `seed` (1, 2, 3 per draw — reproducible
*and* distinct), `temperature` 0.8, `num_ctx` 16384, `num_predict` 12288,
`think:false`, and a 16-char hash of the exact prompt string with every run.

- `think:false` because round 2's run 2a burned its entire 8192-token budget on
  the reasoning block and returned 2 characters of content.
- `num_predict` 12288 for **both** arms. Round 2 used 8192 and it was never
  binding — every short run finished `done_reason: stop` well under 2000 tokens,
  so raising the ceiling cannot change Arm A's behaviour, and it guarantees the
  ledger is never clipped. Budget is therefore not a confound between arms.
- `num_ctx` 16384 holds the ~3.2k prompt plus 12288 of output inside the
  smallest baked context in the fleet, so no model needs a re-bake and no VRAM
  surprise is introduced.

### Not changed, deliberately

The input keeps its **known defect** — `raw/r2-remeasure-input.md:127` titles a
test "99 cards is invalid" over a body reading "98 total". Fixing it would break
comparability with round 2. No arm has ever caught it, so it stands as a free
bonus signal: a reviewer that flags it has genuinely read the test bodies.

The two checklist bullets in `reviewer.md` that telegraph seam 5 are also
**left in both arms**, so the arms differ by one thing only. Removing them is
the obvious round 4 (see Arm C below) — it answers whether seam 5 is being
derived or merely echoed — but it is a second variable and does not belong in
this round.

### Arm C (optional, only if there is time)

`-Arms C` runs Arm B with those two telegraphing bullets stripped. Treat it as a
separate question, not part of the A/B result. Do not substitute it for Arm B.

---

## Running it

From the repo root on the desktop, with Ollama up:

```powershell
# 1. Build the prompts and READ them. No model is called.
.\docs\review-gate\r3-runner.ps1 -WhatIfPrompt

# 2. Full round.
.\docs\review-gate\r3-runner.ps1

# Resumable: existing runs are skipped, so re-running after an interruption
# continues rather than duplicating.
```

Outputs land in `docs/review-gate/raw/r3/`: one `.json` (full API response) and
one `.txt` (extracted content) per run, plus `manifest.tsv`. **All of it gets
committed** — round 2 left five of eight runs in `%TEMP%`, which is why they
cannot be audited.

The script refuses to start if a model is missing (it will not pull — these are
large downloads and that is a human decision), if Ollama is unreachable, or if
`reviewer.md` has changed shape such that the placeholder block no longer
matches.

---

## Rules for whoever runs this

1. **Never open `raw/r2-remeasure-key.md`.** It is the grader's answer sheet. If
   it enters the context of whatever is constructing prompts or summarising
   results, the round is void. The runner hard-fails if it is wired in as a
   prompt source, but it cannot stop a human or an agent from reading it.
2. **Do not grade the outputs.** Collect them verbatim and commit them.
   Grading happens separately, against the key, by someone who did not generate
   the runs. Reporting "the model seemed to catch it" is grading.
3. **Do not edit any prompt file mid-round** — `reviewer.md`,
   `r3-ledger-clause.md`, or the input. That is precisely what invalidated
   round 2's cross-arm comparison. The prompt hash in the manifest will expose
   it if it happens.
4. **Do not re-run a draw because you dislike its answer.** Every run that
   executes goes in the manifest. A discarded draw is a thumb on the scale.
5. **Run sequentially.** The script unloads each model before the next. Do not
   parallelise across models — two 14B models will not co-reside in 16 GB.
6. **Report failures as failures.** If a run errors, times out, or returns
   near-empty content, leave it recorded and say so. Do not paper over it.

## What to report back

- `docs/review-gate/raw/r3/` committed and pushed, in full.
- The `manifest.tsv` contents.
- Anything that deviated from this protocol, however minor — a model that had
  to be pulled, a run that errored, an Ollama version that is not 0.34.0
  (`ollama --version`; round 2's tool-call and VRAM measurements were all taken
  against 0.34.0, and template changes between versions can move results).

## How it will be graded

Against the existing six-seam key, unchanged, plus two additions:

- **Ledger compliance** (Arm B only): did the model actually produce a complete
  per-test table before its verdict, or skip/abbreviate it? A model that ignores
  the clause is not evidence against the hypothesis — it is a separate finding.
- **Bonus:** did it flag the "99 cards / 98 total" name/body mismatch?

The registered decision rule needs one repair before grading: round 2 required
"flags seams 5–6 **and** calls RED-MARK", but `reviewer.md` defines CAUTION as
the correct verdict for "implementation seams uncovered but plan otherwise
sound" — and round 2 counted one CAUTION as a success and an identical CAUTION
as a failure. **For round 3: CAUTION and RED-MARK both count as correctly
declining to pass the plan.** FIRST-RUN-SAFE is the only failing verdict.
