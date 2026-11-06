# Hardware

The fleet that runs the local LLM setup. Refresh the VRAM budget when any node's GPU or RAM changes.

## Machines

| Node | OS | CPU | GPU | VRAM | RAM | IP | Role |
|------|----|-----|-----|------|-----|----|------|
| Server | Ubuntu | Ryzen 7 3700X (8c/16t) | **RTX 4070 Ti Super** (CUDA) | **16 GB** | **32 GB** (Corsair Vengeance LPX) | `SERVER_IP` | Model host: main seat (Ollama and llama.cpp in Docker) |
| Desktop | Windows 11 | Ryzen 7 5800X3D | RX 6800 XT (Vulkan) | 16 GB | 32 GB | `DESKTOP_IP` | Model host, OpenCode client, tool-run host (native Ollama, Vulkan) |
| Third node | Windows 11 | Ryzen 9 5950X | RTX 3080 FE (CUDA) | 10 GB | 32 GB | `NODE3_IP` | Model host, OpenCode client, tool-run host (onboarded 2026-09-20). Also a gaming PC |
| GTX 1070 | — | — | GTX 1070 | 8 GB | — | — | Retired from server Sep 2026; backup / spare candidate |

**Sep 2026 upgrade:** the server switched GPU (GTX 1070 8 GB → RTX 4070 Ti Super 16 GB) and RAM (16 → 32 GB). Everything below assumes the new hardware.

## Specs as read from the machines (2026-11-06)

Read from the machines themselves (Windows CIM, `nvidia-smi`, `/sys`, `lscpu`), not from memory of what was bought.

| | Server | Desktop | node3 |
|---|---|---|---|
| CPU | Ryzen 7 3700X, 8c/16t, 32 MiB L3 | Ryzen 7 5800X3D, 8c/16t, 96 MB L3 | Ryzen 9 5950X, 16c/32t, 64 MB L3 |
| Board | MSI MAG B550 TOMAHAWK MAX WIFI (MS-7C91) | Gigabyte X570 AORUS ELITE | ASUS TUF GAMING X570-PLUS (WI-FI) |
| BIOS | 2.B0, 2026-04-16 | F37, 2022-12-25 | 5003, 2023-10-06 |
| RAM | 2 × 16 GB DDR4, Corsair Vengeance LPX; **speed not readable without `sudo`** (`dmidecode`); XMP is off (`docs/server-recovery-cpu-led.md`) | 2 × 16 GB DDR4, kit part number `F4-3600C16-16GTZNC`, **rated 3600, running 2133 MT/s** | 2 × 16 GB DDR4, TeamGroup UD4-3600, 3600 MT/s (at its rating) |
| GPU | RTX 4070 Ti Super 16 GB, driver 580.178.04, power limit 285 W (max 314 W) | RX 6800 XT 16 GB, driver 32.0.21045.16010 | RTX 3080 10 GB, driver 32.0.16.1692, power limit 320 W, PCIe 4.0 x16 |
| Storage | Samsung PM9A1/980 PRO-class NVMe, 914 GB root, 25% used; 12 GB swap | 4 TB Samsung 870 EVO, 1 TB Crucial P5, 2 TB Crucial MX500 | 1 TB Samsung 980 PRO |
| Network | Realtek RTL8125 2.5 GbE | not read | not read |

- **The desktop's RAM runs at 2133 MT/s although the kit is rated 3600**, so its memory profile (XMP/DOCP) is off. Not
  changed: the desktop has a crash history and a memory profile is the owner's call. node3 runs its kit at the rating.
- **The server's RAM speed is unknown.** `dmidecode` needs `sudo`, which is the owner's step:
  `sudo dmidecode -t memory | grep -E "Speed|Part Number|Manufacturer"` on the server would settle it.

### The server under a real generation (2026-11-06)

One 900-token generation from `qwen3.6:35b-a3b-coding` on the idle server (64k context, `n-cpu-moe 20`, batch 4096),
sampled every 2 seconds over ssh. Decode ran at **65.1 tok/s**.

| Measure | During decode |
|---|---|
| GPU utilisation | 19 to 25% |
| GPU power | 82 to 84 W, against a 285 W limit (SM clock 2,640 MHz) |
| PCIe link | **4.0 x16** (it reads gen 1 while idle: power saving) |
| CPU busy | about 46% of 16 threads (so about 7 threads); clocks 3.7 to 4.25 GHz |
| CPU driver | `amd-pstate-epp`, preference `balance_performance`; the governor reads `powersave`, which is this driver's normal label and was not holding the clocks down |
| RAM | 31.7 GB total, 13 GB in use, 16 GB available |

The GPU waits most of the time during decode and the CPU is busy. **The server is limited by the experts that live in
system RAM and the CPU that computes them, not by the GPU or the PCIe link.** This is one generation, not a sweep.

## What would make the server a stand-alone host (2026-11-06)

The question: the server only serves models, and every harness run borrows node3's or the desktop's CPU for the tools
(`vitest`, `tsc`, `npm`). Both are personal PCs whose CPUs are "nice to have". What would let the server do both?

Starting facts: the served model is **23.0 GB on disk** (`models/catalog.tsv`), so on 16 GB the experts of 20 layers sit
in RAM (`server/llamacpp/models.ini`), and the CPU is already about half busy serving them. Harness work on the same CPU
would compete with decode. **Nothing below was measured on the server. The sizes are arithmetic from the numbers above,
and no speed-up is estimated.**

1. **A GPU that holds the model: 32 GB is the size that does it.** 23 GB of weights plus a 64k KV cache and the compute
   buffers should fit in 32 GB, which removes the spill and frees the CPU. A 24 GB card leaves about 1 GB for everything
   but the weights, so the spill would shrink to a few layers and stay. Whichever card: check the power supply's wattage
   and connectors and the case's clearance first (both unknown; the owner's to read off the machine), and check current
   prices and specs. A second 16 GB card beside the 4070 Ti Super would also reach 32 GB for the model (llama.cpp splits
   layers across cards), but it needs a free slot with at least x4 lanes, which the board's manual should confirm.
2. **A 12 or 16 core Ryzen 5000 chip (5900X or 5950X) in the same socket.** This is for the harness, not for decode: it
   would give the tools their own cores beside the model. Retailer listings say the B550 TOMAHAWK MAX supports Ryzen 5000
   and the BIOS is from April 2026, but **MSI's own page refused an automated read (HTTP 403), so confirm on MSI's CPU
   support list for MS-7C91** before buying.
3. **RAM only after reading its speed.** If a spill remains, RAM bandwidth sets decode speed, and an unknown speed with
   XMP off may be leaving some on the table. XMP froze this board once (`docs/server-recovery-cpu-led.md`), so that is a
   change for the owner to make on purpose, with the CMOS-clear and MOK warning in mind. If the model fits in VRAM, RAM
   speed stops mattering. 64 GB would only be for headroom when running the harness beside the model.
4. **Not limits:** storage (25% used), the network (2.5 GbE), the PCIe link (4.0 x16 under load), the CPU governor.

**Hardware is not the only gap.** The server has no OpenCode client, and the harness is PowerShell with Windows-specific
parts (scheduled tasks, the game yield), so running it on the server means porting and checking it on Linux. That has not
been tried. The cheap first measurement is to run a task's `vitest` and `tsc` on the server while the model decodes, which
shows how much the tools slow the model down, and the other way round, before spending on anything.

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
- Runtime tuning (`server/docker/docker-compose.yml`): `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=2`.
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

## Planning notes

Candidate executor models, upgrade ideas and disk budgets (2026-09-22, not scheduled): [hardware-planning.md](hardware-planning.md).

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
| `qwen3:14b` @32k + `qwen2.5-coder:3b` | **12.34 GB** (13.29 GB in other notes; two measurements, not reconciled) | marginal |
| `qwen3:8b` @32k + `qwen2.5-coder-16k` | **11.97 GB** | yes |

Quantized KV requires flash attention (`quantized V cache requires flash_attn
to be enabled`), and flash attention costs prefill speed on Vulkan — we take
that trade because it is the only way a 14B at 32k keeps a companion model
resident, and an eviction costs more than a slower prefill.
