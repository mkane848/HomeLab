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

How the Go plan bills, per the [Go docs][opencode-go]:
- Each model has a monthly dollar allowance: $15, $30 or $60 on the $10 plan, depending on the model.
- At most 20% of an allowance can be used per 5 hours, and 50% per week.
- `run-tasks-batch.ps1` stops a hosted model once a batch has spent 20% of its allowance (owner's rule, 2026-10-06).

What binds in practice is different (next section). So the batch also checks the plan-wide meters, below.

## Usage limits (what binds in practice)

On 2026-10-06/07 Go refused requests with HTTP 402 ("Insufficient account funds") partway through batches. Timeline and dashboard readings: [archive/costs-usage-limits.md](archive/costs-usage-limits.md).

| Finding | Detail |
|---|---|
| Meters are plan-wide | One rolling 5-hour, one weekly, one monthly meter; no per-model bars |
| Estimated limits (opencode's prices) | Month about $22.30, week about $12.60, 5-hour trailing $4.46. Estimates: Go's own pricing may differ |
| A limit looks like "no funds" | Extra Usage was on with $0.00 credit, so Go tried the balance and found it empty. Nothing was charged. With credit it would bill past the limit |

[`costs/go-plan.tsv`](../costs/go-plan.tsv) holds the limits. Before a hosted batch, `run-tasks-batch.ps1` reads this machine's Go use from opencode's records (interactive use included), shows each meter, and stops every hosted seat within $0.50 of a limit (`-PlanReserveUsd`) or at the provider's first 402.

## What a pass costs (2026-10-06/07)

The first hosted batches ran the private real tasks, one run per task. Results are in `docs/roadmap.md` → "Hosted
seats on the real tasks". Costs here are opencode's own per-message figures, which is what Go's meters count,
summed over every run a seat made.

Each seat stopped at a different point, so the fair comparison is the nine tasks four seats all finished: the
three LFCbot tasks and the first six work packages.

| seat | passed | cost | per pass | total time |
|---|---|---|---|---|
| DeepSeek V4 Pro | 9/9 | $0.52 | $0.06 | 14 min |
| Qwen3.7 Plus | 8/9 | $0.53 | $0.07 | 18 min |
| GLM-5.2 | 9/9 | $2.29 | $0.25 | 31 min |
| Qwen3.8 Max | 9/9 | $3.80 | $0.42 | 44 min |
| Kimi K2.7 Code | 3/3 (LFCbot only) | $0.33 | $0.11 | 5 min |

Over every run, including the harder work packages and runs that weren't graded:

| seat | passed | cost | per pass |
|---|---|---|---|
| Qwen3.7 Plus | 13 of 15 graded | $1.24 | $0.10 |
| DeepSeek V4 Pro | 10 of 10 | $0.85 | $0.09 |
| Kimi K2.7 Code | 3 of 3 | $0.33 | $0.11 |
| Qwen3.8 Max | 9 of 9 | $4.00 | $0.44 |
| GLM-5.2 | 12 of 12 | $6.17 | $0.51 |

- **Runs that weren't graded still cost money.** GLM-5.2's two timeouts cost $1.91 between them, almost a third
  of its total. Three runs refused partway had already billed $0.08–0.20 each before the refusal.
- **Cheap and capable aren't in tension here.** The two cheapest seats passed 17 of 18 shared tasks. Price
  separates them less than their timeouts do. With one run per cell, that's a signal, not a ranking.
- **What the plan buys.** At Qwen3.7 Plus's $0.10 per pass, this month's estimated $22.30 limit covers roughly
  200 passing tasks of this size, at most about half of them in any one week.
- **The local seats cost no API money.** Their electricity isn't recorded yet (below). On the LFCbot tasks
  qwen3.6 passed 9 of 16 runs and qwen3.5:9b 3 of 10. On the 12 work packages, with a 45-minute limit,
  qwen3.6 passed 7 (2026-10-07) and qwen3.5:9b 4 (2026-10-09); Qwen3.7 Plus passed 11 for $1.17. Running qwen3.6 first and handing Qwen3.7 Plus only
  its failures would also end at 11, for $0.63, but in about 3½ hours instead of 49 minutes (`docs/roadmap.md`
  → "Local qwen3.6 on the work packages").
- **DeepSeek is overestimated.** Our own estimate, from `costs/go-rates.tsv` at the peak rate, comes to $1.49 for
  DeepSeek against opencode's $0.85. The runs were inside Go's peak hours, so the gap is unexplained. The other
  seats' estimates match opencode's within a few percent. The Go dashboard is the authority.

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
