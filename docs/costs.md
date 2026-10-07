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

## Usage limits as observed

On 2026-10-06 OpenCode Go began refusing requests with HTTP 402, "Upstream request failed: Insufficient account
funds", partway through a batch. Times are US Eastern, costs are opencode's own per-message figures:
- The first refusal came at 22:09, after about $3.84 of spend across all five models since the first request at
  17:48.
- GLM-5.2 and Kimi K2.7 Code were refused on their first request, although each had used under $0.50 that day.
- Qwen3.8 Max worked again from 22:48, five hours after the first request, and was refused at 23:26 after about $3
  more. That matches its documented per-model limit, 20% of $15.
- On 2026-10-07 GLM-5.2 ran from 08:01. At 09:25 every model was refused within three minutes, after about $12.7
  of spend since 2026-10-06.

The owner's Go dashboard explained it (2026-10-07):
- **The usage meters are plan-wide:** one bar each for a rolling 5-hour window, the week and the month. There are
  no per-model bars.
- **The weekly meter read 100%**, resetting about 2026-10-11 19:00 Eastern. The monthly meter read 72%, renewing
  on the 24th.
- **"Extra Usage" was on** ("use your balance after reaching the limits") **with $0.00 of credit.** So a limit
  shows up as Go trying the balance and finding it empty, hence "Insufficient account funds". Nothing was charged.

Against opencode's records, 72% of the month was $16.08 of use, which puts the month at about $22.30 and the week
at about $12.60, in opencode's prices. The 5-hour meter read 48% after about $5.90 in its window, which doesn't fit
20% of $22.30 ($4.46). Go's own pricing per model may differ from opencode's, so these limits are estimates.

[`costs/go-plan.tsv`](../costs/go-plan.tsv) holds them. Before a hosted batch, `run-tasks-batch.ps1`:
- reads this machine's Go use from opencode's own records, interactive use included;
- shows each meter;
- stops every hosted seat once a meter is within $0.50 of its limit (`-PlanReserveUsd`).

The 5-hour meter is checked as the trailing 5 hours at the conservative $4.46. The batch also stops a model at the
provider's first 402. With Extra Usage on and credit in the balance, Go would bill the balance past a limit
instead of refusing, so the batch's stop is what keeps a batch inside the plan.

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
