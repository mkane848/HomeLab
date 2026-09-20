# Hardware

The fleet that runs the local LLM setup. Refresh the VRAM budget when any node's GPU or RAM changes.

## Machines

| Node | OS | CPU | GPU | VRAM | RAM | IP | Role |
|------|----|-----|-----|------|-----|----|------|
| Server | Ubuntu | Ryzen 7 3700X (8c/16t) | **RTX 4070 Ti Super** (CUDA) | **16 GB** | **32 GB** (Corsair Vengeance LPX) | `SERVER_IP` | Primary Ollama node (Docker) |
| Desktop | Windows 11 | Ryzen 7 5800X3D | RX 6800 XT (Vulkan) | 16 GB | ? | `DESKTOP_IP` | Native Ollama (Vulkan) |
| Third node *(future)* | Windows 11 | Ryzen 9 5950X | RTX 3080 FE (CUDA) | 10 GB | 32 GB | `NODE3_IP` | Third node (general + embed) |
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
- Node3's GPU (if onboarded): CUDA 10 GB — good for 7–9B, tight for 12–14B.

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