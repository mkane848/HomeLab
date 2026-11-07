# Methodology caveats

How far the benchmark's numbers can be trusted, in one page. The method, today's intervals and the runs each question needs: [methodology.md](methodology.md). Terms: [glossary](glossary.md). Detail: [methodology-research.md](methodology-research.md), [2026-09-29 review](adversarial-review-2026-09-29.md), [2026-10-23 review](adversarial-review-2026-10-23.md).

## How to read a number here

| Rule | Why |
|---|---|
| Treat every result as **unreplicated** unless it says otherwise | Cells are small: the largest single round is 96 runs (16 tasks × 6, 2026-11-01), from 3 repos; reps are now sized by power ([methodology.md](methodology.md#how-many-runs-a-question-needs)) |
| Compare only within one **era** | Engine, plugins, classifier, checkout and shell changed mid-corpus ([tests/results/README.md](../tests/results/README.md) → "Era confound") |
| Prefer "passes every time" (pass^k) over per-run rates for unattended work | Runs of one task are correlated |
| Do not quote p-values in headline docs | Tests were run after looking at the data and are not corrected for multiple comparisons; they stay in the dated logs |
| Pair by task; do not pool runs | Runs cluster by task, so a test on pooled totals overstates the evidence ([methodology.md](methodology.md#how-to-compare-two-arms)). Older logged values have that flaw; none of them claimed a difference |
| Ask what the owner's own fix scores | The owner's real fix does 31% of the Ideal list, so 24% is near shipped work, not far below it |
| A probe PASS is not a seat | See [tool-calling.md](tool-calling.md) |

## Who checked what

| Review | Reviewer | Independent? |
|---|---|---|
| 2026-09-29 | Claude subagent | No: same model family as the work it reviews |
| 2026-10-23 | Claude Sonnet subagent, then re-checked by the main Claude session | No: model-reviewed-by-model. Numbers were recomputed from the run JSONs, which is the useful part; the conclusions are still a model's reading |
| 2026-11-07 | The main Claude session, on its own recent work | No: the author checking itself. Counts were recomputed by a separate script, which held; the errors found were of method and framing ([audit](planner-tests-experiment.md#audit-of-these-numbers-2026-11-07)) |

## Open items

| Item | State |
|---|---|
| Contamination / holdout | No membership check against the models' training data and no holdout set. "Oracle passes" could be recall |
| VRAM figures | `qwen3:14b` + 3b is 12.34 GB in `hardware.md` and 13.29 GB elsewhere; unreconciled, and desktop figures date from Ollama 0.34.0 |
| Review-gate result | 18 runs, floor effect; "no" is a small-n answer, not a settled one |
| Planner-written tests | [Experiment](planner-tests-experiment.md) screened (2026-10-31: 3 false positives in 28, 4% to 27%) and run live (2026-11-02 and 11-05: 0 wrong in 12). Whether the rate is under 10% needs about 35 accepted attempts; those come from real work and the owner's verdicts. A Gate could read outside the checkout until the clean-copy recheck of 2026-11-06, which has only 6 sets of live evidence |
| Local planner | Audited 2026-11-07. No run yet with no frontier model at all: Opus wrote every confirmed list. Six tasks cannot rank it against Opus |
| Shown vs hidden lift | Not established: 4 tasks carry the whole difference |
| Hand-checked claims | A lint ([tests/lint-doc-claims.sh](../tests/lint-doc-claims.sh), run in CI) blocks the claims the 2026-10-23 review retired from the public docs |
