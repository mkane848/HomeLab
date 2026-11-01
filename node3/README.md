# node3: llama-server

node3 (RTX 3080 FE 10 GB, Ryzen 9 5950X) is the fleet's run host first. This folder is its model-host half on
llama.cpp: "Replacing Ollama" Phase 5 in [`docs/roadmap.md`](../docs/roadmap.md), started 2026-10-31. Ollama keeps
running beside it until Phase 6.

| File | What |
|---|---|
| [`llamacpp/models.ini`](llamacpp/models.ini) | the router preset: one seat, `qwen3:8b`, same weights and sampling as node3's Ollama copy and the server's seat |
| [`scripts/start-llama-server.ps1`](scripts/start-llama-server.ps1) | registers the scheduled task `HomeLab-llamacpp` (starts at boot) and starts it; `-Lan` to listen on the LAN, `-Stop` to remove it |

## Install

The build is pinned: llama.cpp **b11562**, Windows CUDA 12.4. The server runs b11561 in Docker, and that build has no
Windows release; b11562 is the next commit. Unpack both zips from the
[b11562 release](https://github.com/ggml-org/llama.cpp/releases/tag/b11562) into `C:\HomeLab\llama.cpp\b11562\`, after
checking them against the digests GitHub publishes for them:

| Asset | sha256 |
|---|---|
| `llama-b11562-bin-win-cuda-12.4-x64.zip` | `e06a4659435981acc93d4ef37ae6046b72754af968aa2cd6f476a9fa5c4f765c` |
| `cudart-llama-bin-win-cuda-12.4-x64.zip` | `8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6` |

Then, from this checkout on node3: `pwsh -File node3\scripts\start-llama-server.ps1`.

The preset's `model` path is node3's own Ollama blob (`C:\Users\danaj\.ollama\models\blobs\sha256-a3de86…`): the same
bytes as the server's `qwen3:8b` seat (`models/server-seats.tsv`), so a difference in results is the engine, not the
weights.

## On the LAN (the owner's step)

The task listens on `127.0.0.1` until a firewall rule lets the LAN in. Listening on `0.0.0.0` without one makes Windows
show a firewall prompt on node3's screen. In an elevated PowerShell on node3:

```powershell
New-NetFirewallRule -DisplayName "llama-server 8090 (LAN)" -Direction Inbound -Protocol TCP -LocalPort 8090 -RemoteAddress 192.168.1.0/24 -Action Allow
```

then `pwsh -File node3\scripts\start-llama-server.ps1 -Lan`. `profiles/dev-node3.sh` already points
`LLAMACPP_NODE3_BASE_URL` at `http://<NODE3_IP>:8090/v1`.

## Measured (2026-10-31, `qwen3:8b`)

| Check | llama.cpp b11562 | Ollama 0.40.4 (same host, same weights) |
|---|---|---|
| tool-call probe (`tests/test-toolcalls.ps1 -Engine llamacpp`) | PASS, 15.4 s | PASS (2026-09-20, on 0.34.x) |
| over-long request (`tests/probe-overflow.ps1`, ~42,600 tokens at 32,768) | **EXPLICIT-ERROR**: HTTP 400, which OpenCode classifies as a context overflow | SILENT-TRUNCATION: evaluated 16,386 tokens (38%), no error (2026-10-14) |
| prefill / decode at 3k, 16k, 30k tokens (`tests/bench-speed.ps1`, 2 reps) | 4,290 / 3,454 / 2,820 · 97.8 / 72.8 / 57.1 tok/s | 4,237 / 3,405 / 2,777 · 97.2 / 73.1 / 57.1 tok/s |

Rows: `tests/results/toolcalls-summary-llamacpp.tsv`, `tests/results/overflow-probe.tsv`,
`tests/results/bench-speed.tsv`.

## Known gaps

- **The harness's GPU-placement check does not work against node3's llama-server.** `Get-EngineGpuPlacement` in
  `tests/engines/llamacpp.ps1` runs `nvidia-smi --query-compute-apps=pid,used_memory` and `ps -eo pid,args` over ssh:
  `ps` is Linux-only, and on Windows (WDDM) `nvidia-smi` reports every process's memory as `[N/A]`. A run against
  `llamacpp-node3` records placement `unchecked` (a WARN, not a grade). A Windows branch would read process command
  lines through CIM and the card's total `memory.used`.
- The two engines share the 10 GB card. Unload one before loading a seat on the other.
