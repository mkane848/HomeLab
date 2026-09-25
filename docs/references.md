# References & citations

Catalog of every external source cited in these docs, plus the convention.

## Convention

- **Any doc claim grounded in an external source** (paper, leaderboard,
  benchmark, blog, tool docs) links that source inline on **first mention**,
  with descriptive link text — never a bare URL and never a guessed URL.
- Every inline-cited source gets a row here: **short name — title, author/lab,
  date, URL**.
- A URL that exists only to check a fact (product page, registry, docs) is
  linked inline; only sources actually *cited as evidence* need catalogue
  entries.
- **Re-verify stale-able claims when editing a doc that carries them.**
  Leaderboard ranks, "best model" statements, and version facts move weekly;
  this repo's value is measured truth, so a 2026-07 leaderboard reading must be
  re-fetched before a 2026-09 doc relies on it. If you cannot re-verify, keep
  the claim but date-stamp it (e.g. "as of 2026-07").
- When you add the first citation from a new source to any doc, add the source
  row here in the same change so the page never lags the docs.

## Papers (arXiv)

| ID | Source | URL |
|---|---|---|
| saving-swebench | "Saving SWE-Bench: A Benchmark Mutation Approach for Realistic Agent Evaluation", arXiv 2025 | <https://arxiv.org/html/2510.08996v2> |
| reward-hacking | "Reward Hacking Benchmark", arXiv 2026 | <https://arxiv.org/abs/2605.02964> |
| mirage-bench | "MIRAGE-Bench", arXiv 2025 | <https://arxiv.org/abs/2507.21017> |
| dont-blame-llm | "Don't Blame the Large Language Model: How Scaffolding Evolution Shapes Coding Agent Quality", arXiv 2026 | <https://arxiv.org/pdf/2607.03691> |
| swe-edit | "SWE-Edit: Rethinking Code Editing for Efficient SWE-Agent", Microsoft, arXiv 2026-05 | <https://arxiv.org/html/2604.26102> |
| terminal-agents | "Building AI Coding Agents for the Terminal", arXiv 2026-03 | <https://arxiv.org/html/2603.05344v1> |

Where used: `saving-swebench`, `reward-hacking`, `mirage-bench`,
`dont-blame-llm` → [roadmap.md](roadmap.md) ("external research pass");
`swe-edit`, `terminal-agents` → [methodology-research.md](methodology-research.md).

## Leaderboards & benchmarks

| ID | Source | URL |
|---|---|---|
| swe-bench-verified | SWE-bench Verified leaderboard + methodology, official | <https://www.swebench.com/> |
| modelfit-swe | ModelFit "Local vs Cloud: SWE-Bench Verified" (raw-confirmed open-weight scores) | <https://modelfit.io/benchmark/> |

Where used: → [methodology-research.md](methodology-research.md) ("Model fits"),
and `swe-bench-verified` is the reference named throughout
[roadmap.md](roadmap.md) for the mechanical-gate methodology.

## Engineering docs & analysis

| ID | Source | URL |
|---|---|---|
| aider-edit-formats | Aider — edit formats (whole, diff, udiff) | <https://aider.chat/docs/more/edit-formats.html> |
| aider-unified-diffs | Aider — "Unified diffs make GPT-4 Turbo 3x less lazy" (edit-format + flexible-apply analysis) | <https://aider.chat/docs/unified-diffs.html> |
| qcoda-bakeoff | QCoda — "We Tested Every Agentic Coding Engine Against Every Local Model" (engine × model, edit-format + round-trip analysis, 2026-06) | <https://qcoda.com/blog/engine-model-bakeoff> |

Where used: → [methodology-research.md](methodology-research.md) ("Edit
reliability", "Whole-file vs search-replace", "Harness round-trip weight").

## Software & code

| ID | Source | URL |
|---|---|---|
| swe-edit-repo | SWE-Edit (Viewer/Editor edit decomposition, PR-Edit eval) | <https://github.com/microsoft/SWE-Edit> |
| metaharness-adr127 | agent-harness-generator ADR-127 — search/replace patch primitive vs whole-file on large files (2026-06, run-to-run stable) | <https://github.com/ruvnet/metaharness/blob/4db1c8f8/docs/adrs/ADR-127-darwin-searchreplace-patch-primitive.md> |

Where used: `swe-edit-repo` → the paper row above; `metaharness-adr127` →
independent confirmation of the whole-file-on-large-files regression documented
in [methodology-research.md](methodology-research.md).

## Another page to cite from

If a source is new and not yet here, add a row in the matching table. If a
source has no table yet, add one — the grouping above is the current shape, not
a fixed taxonomy.