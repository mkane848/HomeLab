# Hardware planning notes (not scheduled)

Moved out of [hardware.md](hardware.md). Nothing in [target-setup.md](target-setup.md) depends on these. Candidate lists date from 2026-09-22 and have since been partly probed (see `tests/results/toolcalls-summary.tsv`).

## Candidate executor models (Ollama library scan, 2026-09-22)

Not yet probed. Each needs `tests/test-toolcalls.ps1` before anything else,
then the task batch. The rationale is in [target-setup.md](target-setup.md).
Sizes are Ollama's Q4 download sizes. Budget from `/api/ps` once pulled.

| Model | Size | Type | Host | Note |
|---|---|---|---|---|
| `devstral-small-2:24b` | 15 GB | dense 24B, agentic coder (Mistral, 2512) | desktop / server | Successor to the installed `devstral:24b` (2505). Dense, so any spill is slow |
| `north-mini-code-1.0` | 19 GB | 30B MoE, 3.2B active, agentic coder (Cohere) | desktop / server | Same shape as `qwen3-coder:30b-a3b` |
| `laguna-xs-2.1` | 20 GB | 33B MoE, 3B active, agentic coder | desktop / server | Released ~2026-09. May need a newer Ollama than 0.34.1 |
| `qwen3.6:35b-a3b-coding` | 23 GB | 35B MoE, 3B active, coder variant | server (desktop only with Docker idle) | In-family successor to `qwen3-coder` |
| `nemotron-3.5-lightning` | 25 GB | 30B MoE, 3B active, agent-general (NVIDIA) | server | Not coding-specific. Heaviest spill |
| `ornith:9b` | 5.6 GB | 9B, RL-trained for agentic coding | **node3** | Only small model aimed squarely at coding agents |
| `ministral-3:8b` | 6.0 GB | 8B, tools (Mistral) | **node3** | General tool caller |
| `lfm2.5:8b` | 5.2 GB | 8B MoE, ~1B active, tool-calling focus | node3 | Fast, likely too weak to write fixes |

Skipped: `muse-glimmer:30b` (dense 30B at 18 GB, spill would be slow),
`gpt-oss:20b` (optional baseline only), and everything cloud-only or 50 GB+
(GLM-5.x, Kimi, MiniMax, DeepSeek V4, `qwen3-coder-next` at 52 GB,
`qwen3.8-flash-next`).

## Upgrade candidates (for AI, not scheduled)

Nothing in [target-setup.md](target-setup.md) depends on these. Recorded
2026-09-22 at the owner's request, ordered by expected impact. No prices are
listed because they move too fast to record.

1. **node3: RTX 3080 10 GB → a 24 GB card (e.g. a used RTX 3090).** The
   biggest single change. The 30B-A3B coder class (18–20 GB) would fit
   *entirely* in VRAM with room for context, turning node3 from a ~9B
   side-worker into a second full executor beside the server. Check the PSU
   first: a 3090 draws ~350 W with large transient spikes, against the 3080
   FE's ~320 W.
2. **Server: 32 GB → 64 GB RAM** (DDR4, AM4). Lets the server run the 50 GB
   MoE class (e.g. `qwen3-coder-next` at 52 GB: 16 GB in VRAM, ~36 GB spilled)
   and keep more than one large model resident. Throughput on dual-channel
   DDR4 is unmeasured, so treat it as an experiment, not a promise.
3. **node3: 32 GB → 64 GB RAM.** Only worth it if item 1 does not happen. It
   lets node3 run the 18–20 GB MoE coders with heavy spill, slower than the
   server but a real second executor.
4. **GTX 1070 as a second server GPU**, if the server has a free slot and PSU
   headroom (both unrecorded). It could take embeddings or a small model off
   the 4070 Ti Super so the main executor keeps all 16 GB. Low impact, zero
   cost.
5. **Desktop: no GPU upgrade for AI.** It is Vulkan-only on this card (see
   below), it is the gaming machine, and the target setup keeps it off the
   critical path. More RAM only if it ends up a regular executor.

## Network and storage

- **LAN:** all three machines are wired (confirmed 2026-09-22). Every agent turn
  re-sends the prompt to the model host, so this matters for remote seats.
- **Storage:** there is enough space and there are spare SSDs, so disk is not
  a constraint. Budget from the totals below.

Disk needed per option (Ollama Q4 download sizes; Ollama dedupes shared blobs,
so derived `-16k`/`-32k` aliases cost almost nothing):

| What | Host | Disk |
|---|---|---|
| Currently installed (measured 2026-09-22, `~/.ollama/models/blobs`) | desktop (C:) | **85.8 GB** |
| All five large candidates: `devstral-small-2` 15 + `north-mini-code-1.0` 19 + `laguna-xs-2.1` 20 + `qwen3.6:35b-a3b-coding` 23 + `nemotron-3.5-lightning` 25 | desktop now, server later | **~102 GB** |
| Top three only (`devstral-small-2`, `north-mini-code-1.0`, `laguna-xs-2.1`) | desktop / server | ~54 GB |
| Small candidates: `ornith:9b` 5.6 + `ministral-3:8b` 6.0 + `lfm2.5:8b` 5.2 | node3 | **~17 GB** |
| Server steady state: executor winner + runner-up + `qwen3:8b`/`qwen3:14b` + embeddings | server | ~60–70 GB |
| Upgrade-gated: `qwen3-coder-next` (needs 64 GB RAM) | server | +52 GB |

The desktop's models live on C:, which had **204 GB free** on 2026-09-22.
The full candidate set fits and leaves ~100 GB. If C: gets tight, point
`OLLAMA_MODELS` at M: (3.4 TB free) instead of pruning. Losing candidates
costs nothing: a failed probe means `ollama rm`.

