# Hardware

The fleet that runs the local LLM setup. Refresh the VRAM budget when any node's GPU or RAM changes.

## Machines

| Node | OS | CPU | GPU | VRAM | RAM | IP | Role |
|------|----|-----|-----|------|-----|----|------|
| Server | Ubuntu | Ryzen 7 3700X (8c/16t) | **RTX 4070 Ti Super** (CUDA) | **16 GB** | **32 GB** (Corsair Vengeance LPX) | `SERVER_IP` | Primary Ollama node (Docker) |
| Desktop | Windows 11 | Ryzen 7 5800X3D | RX 6800 XT (Vulkan) | 16 GB | 32 GB | `DESKTOP_IP` | Native Ollama (Vulkan) |
| Third node | Windows 11 | Ryzen 9 5950X | RTX 3080 FE (CUDA) | 10 GB | 32 GB | `NODE3_IP` | Onboarded 2026-09-20 (general + embed) |
| GTX 1070 | — | — | GTX 1070 | 8 GB | — | — | Retired from server Sep 2026; backup / spare candidate |

**Sep 2026 upgrade:** the server switched GPU (GTX 1070 8 GB → RTX 4070 Ti Super 16 GB) and RAM (16 → 32 GB). Everything below assumes the new hardware.

## VRAM budget (approx, Q4_K_M)

GGUF weights are roughly `params × 0.6` GB at Q4, plus KV cache and ~1–2 GB runtime overhead:

| Size | Weights ~ | 8 GB | 10 GB | 16 GB |
|------|-----------|------|-------|-------|
| 7B | 4.7 GB | ✓ | ✓ | ✓ |
| 8–9B | 5.5–6 GB | tight | ✓ | ✓ |
| 12B | 8 GB | ✗ | tight | ✓ |
| 14B | 9–9.5 GB | ✗ | tight | ✓ |
| 20–22B dense/MoE-4B | 13–14 GB | ✗ | ✗ | **edge** (`offload`) |
| 32B | 20 GB | ✗ | ✗ | ✗ (needs system RAM offload) |

`class` in `models/catalog.tsv`:
- `fit` — comfortable on 16 GB VRAM.
- `edge` — fits on 16 GB but tight (~14 GB weights); watch context/KV.
- `offload` — too big for 16 GB VRAM; needs CPU/RAM offload, slow but usable.

## What changed with the 4070 Ti Super

- 16 GB VRAM is 2× the old GTX 1070 → the server can now run 14B models fully on GPU and keep 7B + 14B loaded simultaneously.
- 32 GB RAM (vs 16 GB) → meaningful CPU offload for `offload`-class models.
- Docker Ollama honors `OLLAMA_CONTEXT_LENGTH`, so the server default context was raised 8192 → 16384 (`server/docker/.env.example`).
- Runtime tuning targets: `OLLAMA_NUM_PARALLEL=4`, `OLLAMA_MAX_LOADED_MODELS=2` (see `server/docker/docker-compose.yml`).
- CUDA-only tooling (vLLM, TensorRT-LLM, CUDA llama.cpp) is now possible on the server — the Vulkan desktop cannot run those. See `roadmap.md`.

## RAM available for spill (2026-09-22)

All three machines have 32 GB, but not the same amount is free for a model
that spills past VRAM:

- **Desktop:** `.wslconfig` caps WSL at 12 GB when Docker is running, and
  Windows plus open apps take another ~6–8 GB, leaving **~10–14 GB**. Fine for
  18–20 GB models (4–6 GB spill). 23–25 GB models (9–11 GB spill) only with
  Docker idle.
- **Server:** no WSL cap and no desktop apps, so it is the best host for spill.
- **Spill only works for MoE models.** A dense model falls off a cliff (see the
  `devstral:24b` numbers below: 7.5% spilled, 49 → 8.1 tok/s). A MoE that
  runs ~3B parameters per token tolerates much more spill. Measure with
  `/api/ps` before seating either kind.

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

Also unrecorded: free disk per machine (models are 15–25 GB each) and whether
the hosts are on wired gigabit.

## Verify the new hardware

1. `nvidia-smi` on the server shows `RTX 4070 Ti SUPER 16 GB`.
2. Free VRAM should be ~14 GB with nothing loaded.
3. `./server/scripts/status.sh` → GPU section + `api/ps` shows loaded context/VRAM per model.
4. Pull a 14B coder and confirm it runs fully in GPU: `install-model.sh coder`.

If the server won't POST (solid CPU EZ Debug LED), see the recovery log:
[`docs/server-recovery-cpu-led.md`](server-recovery-cpu-led.md).

## GPU/API gaps

- Server: CUDA, best software ecosystem (see roadmap for alternatives).
- Desktop: **Vulkan**, not ROCm — see below. No vLLM/TensorRT.
- Node3: CUDA 10 GB — good for 7–9B (`qwen3:8b` is the measured, tool-capable agent seat; `glm4:9b` is a no-tools chat model, confirmed by probe), tight for 12–14B (`qwen3:14b` deliberately not registered on this host).

## Desktop backend: Vulkan (settled 2026-09-17)

Earlier revisions of these docs described the desktop as "native ROCm". It is
not, and it cannot be. Ollama runs the **Vulkan** backend on the RX 6800 XT:

```
library=Vulkan ... Vulkan0 (AMD Radeon RX 6800 XT) (16368 MiB)
```

Ollama 0.34 requires the HIP 7 runtime (`amdhip64_7.dll`) for its ROCm path.
Adrenalin 26.8.1 (WDDM 32.0.21045.5002) ships `amdhip64_6.dll` only — and a
driver update will not help, because **gfx1030 is not on AMD's Windows HIP
support list** (7.2 marks RX 6950/6900/6800 XT/6800 unsupported; Windows HIP is
RDNA3 + RDNA4 only). Forcing `OLLAMA_VULKAN=0` drops the box to CPU-only.
Full reasoning and citations: [`docs/troubleshooting.md`](troubleshooting.md)
→ "ROCm not detected".

Measured on Vulkan, `qwen2.5-coder:14b` Q4:

| Metric | Value |
|---|---|
| Generation | 49 tok/s |
| Prefill, `FA=1 KV=q8_0` | 103 tok/s |
| Prefill, `FA=0 KV=f16` | 191 tok/s |
| Cold model load | 14.1 s |

### Runtime VRAM (measured, not catalog disk size)

Only ~14.8 GB of the 16 GB is usable. Catalog `size_gb` is the GGUF on disk and
omits KV cache + compute buffers, so it undercounts by 1–3 GB — budget from
`/api/ps`, not from `catalog.tsv`. With `OLLAMA_FLASH_ATTENTION=1` and
`OLLAMA_KV_CACHE_TYPE=q8_0`:

| Model | Context | VRAM | Generation | Fully on GPU? |
|---|---|---|---|---|
| `qwen3:14b` | 32768 | **11.03 GB** | 48.9 tok/s | yes |
| `qwen3:8b` | 32768 | 7.16 GB | 79.8 tok/s | yes |
| `qwen3:8b` | 16384 | 5.93 GB | — | yes |
| `qwen2.5-coder:14b` | 32768 | 11.27 GB | 49.3 tok/s | yes |
| `deepseek-r1-32k` | 32768 | 12.11 GB | — | yes |
| `qwen2.5-coder-16k` (7b) | 16384 | 4.81 GB | — | yes |
| `qwen2.5-coder:3b` | 16384 | 1.3–2.3 GB | — | yes |
| `devstral:24b` | 16384 | 13.89 GB of 15.01 | **8.1 tok/s** | **no — 92.5%** |

**Devstral is the cautionary number.** Only **7.5%** of it spilled to system RAM
— 1.1 GB — and throughput fell from ~49 tok/s to **8.1**. A dense model does not
degrade gracefully past the VRAM edge; it falls off it. This is why `class` in
the catalog matters and why "it fits on disk" is not the same as "it fits."

Working pairs, both verified co-resident via `/api/ps`:

| Pair | VRAM | Fits while gaming (~12.5 GB)? |
|---|---|---|
| `qwen3:14b` @32k + `qwen2.5-coder:3b` | **12.34 GB** | marginal |
| `qwen3:8b` @32k + `qwen2.5-coder-16k` | **11.97 GB** | yes |

Quantized KV requires flash attention (`quantized V cache requires flash_attn
to be enabled`), and flash attention costs prefill speed on Vulkan — we take
that trade because it is the only way a 14B at 32k keeps a companion model
resident, and an eviction costs more than a slower prefill.