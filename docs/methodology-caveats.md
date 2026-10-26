# Methodology caveats

How far the benchmark's numbers can be trusted, in one page. Terms: [glossary](glossary.md). Detail: [methodology-research.md](methodology-research.md), [2026-09-29 review](adversarial-review-2026-09-29.md), [2026-10-23 review](adversarial-review-2026-10-23.md).

## How to read a number here

| Rule | Why |
|---|---|
| Treat every result as **unreplicated** unless it says otherwise | Cells are 3–5 runs of 15 tasks from 3 repos; 12 of 15 tasks are saturated in most rounds |
| Compare only within one **era** | Engine, plugins, classifier, checkout and shell changed mid-corpus ([tests/results/README.md](../tests/results/README.md) → "Era confound") |
| Prefer "passes every time" (pass^k) over per-run rates for unattended work | Runs of one task are correlated |
| Do not quote p-values in headline docs | Tests were run after looking at the data and are not corrected for multiple comparisons; they stay in the dated logs |
| A probe PASS is not a seat | See [tool-calling.md](tool-calling.md) |

## Who checked what

| Review | Reviewer | Independent? |
|---|---|---|
| 2026-09-29 | Claude subagent | No: same model family as the work it reviews |
| 2026-10-23 | Claude Sonnet subagent, then re-checked by the main Claude session | No: model-reviewed-by-model. Numbers were recomputed from the run JSONs, which is the useful part; the conclusions are still a model's reading |

## Open items

| Item | State |
|---|---|
| Contamination / holdout | No membership check against the models' training data and no holdout set. "Oracle passes" could be recall |
| VRAM figures | `qwen3:14b` + 3b is 12.34 GB in `hardware.md` and 13.29 GB elsewhere; unreconciled, and desktop figures date from Ollama 0.34.0 |
| Review-gate result | 18 runs, floor effect; "no" is a small-n answer, not a settled one |
| Planner-written tests | [Experiment](planner-tests-experiment.md) not run; the shown-test selector is an oracle, so retry-loop numbers are best case |
| Shown vs hidden lift | Not established: 4 tasks carry the whole difference |
| Hand-checked claims | A lint ([tests/lint-doc-claims.sh](../tests/lint-doc-claims.sh), run in CI) blocks the claims the 2026-10-23 review retired from the public docs |
