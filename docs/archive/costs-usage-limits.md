# OpenCode Go usage limits: the 2026-10-06/07 incident

Moved out of [`docs/costs.md`](../costs.md). Times are US Eastern; costs are opencode's own per-message figures.

| When | What happened |
|---|---|
| 2026-10-06 22:09 | First HTTP 402 ("Upstream request failed: Insufficient account funds") mid-batch, after about $3.84 across all five models since 17:48 |
| 2026-10-06 | GLM-5.2 and Kimi K2.7 Code refused on their first request, each having used under $0.50 that day |
| 2026-10-06 22:48 / 23:26 | Qwen3.8 Max worked again five hours after its first request, then was refused after about $3 more: its per-model limit, 20% of $15 |
| 2026-10-07 09:25 | Every model refused within three minutes, after about $12.7 of spend since 2026-10-06 |

What the owner's Go dashboard showed (2026-10-07):

- The meters are plan-wide: one bar each for a rolling 5-hour window, the week and the month. No per-model bars.
- The weekly meter read 100% (reset about 2026-10-11 19:00 Eastern); the monthly read 72% (renews on the 24th).
- "Extra Usage" was on with $0.00 credit, so a limit showed up as Go trying the balance and finding it empty. Nothing was charged.

Against opencode's records, 72% of the month was $16.08, putting the month at about $22.30 and the week at about $12.60 in opencode's prices. The 5-hour meter read 48% after about $5.90, which does not fit 20% of $22.30 ($4.46). Go's own per-model pricing may differ from opencode's, so these limits are estimates (`costs/go-plan.tsv`).

With Extra Usage on and credit in the balance, Go would bill the balance past a limit instead of refusing, so the batch's own stop is what keeps a batch inside the plan.
