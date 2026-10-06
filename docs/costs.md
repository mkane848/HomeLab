# What it costs

This repo measures what local and hosted models can do on real work. This page is the money side, so someone
reading the results can weigh "run it myself" against "pay for a plan". Every price here is dated. When a price
changes, a new row is added and the old one is kept, so each result keeps the prices of its day.

## Recorded today

| what | where | notes |
|---|---|---|
| what the owner pays for model access | [`costs/access.tsv`](../costs/access.tsv) | [Claude Pro][claude-pricing], $20/month; [OpenCode Go][opencode-go], $10/month (both checked 2026-10-06) |
| per-token rates for the hosted seats | [`costs/go-rates.tsv`](../costs/go-rates.tsv) | OpenCode Go's published rates and per-model monthly allowances for the five seats in use |
| tokens used by every run | each run JSON's `usage` | input, cached input, output and reasoning tokens, and steps, summed over every turn |
| what a hosted run cost | each run JSON's `costEstimate` | `usage` × that model's rates. Null for a model without a rate row, which today is every local seat |

How the Go plan bills:
- Each model has a monthly dollar allowance: $15, $30 or $60 on the $10 plan, depending on the model.
- At most 20% of an allowance can be used per 5 hours, and 50% per week ([OpenCode Go][opencode-go]).
- `run-tasks-batch.ps1` stops a hosted model once a batch has spent 20% of its allowance (owner's rule, 2026-10-06),
  so a batch never locks a model for longer than one 5-hour window.

## Not recorded yet

- **Electricity for the local seats.** It needs the owner's rate per kWh and a measured power draw. `qwen3.6` runs
  partly on the CPU, so GPU power alone undercounts.
- **Hardware.** It will be shown separately, because "I already own the GPU" and "I'd buy one for this" are
  different questions.
- **The Claude comparison.** The plan's price is known; what the same tasks cost and achieve through Claude Code
  needs a client-neutral run of the benchmark (`docs/roadmap.md` → "Is this OpenCode, or the plan?").

Every past run already has its tokens and wall-clock time, so these can be filled in afterwards without re-running
anything.

[claude-pricing]: https://claude.com/pricing
[opencode-go]: https://opencode.ai/docs/go
