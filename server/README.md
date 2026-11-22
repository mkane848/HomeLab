# Server (Ubuntu)

Scripts and configs for the Ubuntu server: the fleet's model host. llama.cpp's `llama-server` is its only engine: the
primary since 2026-11-01, and the only one since Ollama was removed from the fleet on 2026-11-21. The server has no
OpenCode client, and the tools run on node3 or the desktop.

## Hardware

- AMD Ryzen 7 3700X (8c/16t)
- **RTX 4070 Ti Super (16 GB VRAM, Ada, CUDA)** — replaced a GTX 1070 in Sep 2026
- **32 GB DDR4 (Corsair Vengeance LPX)** — up from 16 GB
- MSI MAG B550 TOMAHAWK MAX WIFI (MS-7C91), BIOS 2.B0 (2026-04-16); GPU on PCIe 4.0 x16; 2.5 GbE; NVMe root (read 2026-11-06)
- More detail, the measured load profile and what would let it run the harness itself: [docs/hardware.md](../docs/hardware.md)

## What Runs Here

- **`qwen3.6:35b-a3b-coding`**: the main seat, on `llama-server` in Docker (`docker/docker-compose.llamacpp.yml`, port
  8090, router mode, presets in `llamacpp/models.ini`). It reaches OpenCode through the `dev-workflow-server-llamacpp`
  profile, the default.
- **Other seats in the same preset**, such as `qwen2.5-coder-3b-cpu` (OpenCode's small model, on the CPU) and
  `qwen3:8b`; the full list, each with its context and weights `sha256`, is `../models/server-seats.tsv`.
- The weights are GGUF files in `~/models` (the container's `/models`).
- The household stack (`docker/docker-compose.household.yml`, `household/`): [docs/household-assistant.md](../docs/household-assistant.md).

## Quick Start

```bash
cd ~/HomeLab
./server/scripts/startup.sh        # start llama-server (systemd unit if installed, else docker compose)
./server/scripts/status.sh         # the engine, its container and restart policy, the GPU, the seats
./server/scripts/llamacpp-check.sh --url http://localhost:8090 --weights-container llamacpp-server
                                   # the preset against models/server-seats.tsv, the live server, the weights
./server/scripts/stop.sh           # stop it
```

The API key on the engine (`--api-key-file`) and how each client finds it: [docs/engine-api-keys.md](../docs/engine-api-keys.md).

## Adding a model

Copy the GGUF into `~/models`, add a section to `llamacpp/models.ini` and a row (its `sha256`, source `import-server`)
to `../models/server-seats.tsv`, register it in `opencode/global/opencode.jsonc`, restart, run `llamacpp-check.sh`, then
probe it from the desktop or node3:

```powershell
.\tests\test-toolcalls.ps1 -Engine llamacpp -EngineHost http://SERVER_IP:8090 -Model <tag>
```

Each step in full: [docs/reference/config.md](../docs/reference/config.md) → "Adding a model".

## Startup Methods

| Method | When to use |
|--------|-------------|
| `docker compose` | Default. Good for dev, easy to tear down. |
| `systemd` | Persistent across reboots, auto-restart on crash. |

`startup.sh` auto-detects: if the systemd unit is installed (`llamacpp-server.service`), it uses `systemctl`; otherwise
it falls back to `docker compose up -d`. The container's own policy is `restart: unless-stopped`.

## Files

- `docker/docker-compose.llamacpp.yml` — the llama-server stack: CUDA image pinned to a build, the five `/dev/nvidia*`
  nodes listed explicitly, a healthcheck that fails when the container loses the GPU, `--api-key-file`
- `docker/docker-compose.household.yml` — the household stack
- `docker/.env.example` — copy to `.env` and fill in values
- `llamacpp/models.ini` — the router preset: one section per seat, with its contracts in the header; `llamacpp/templates/` — chat templates it loads
- `systemd/llamacpp-server.service` — systemd unit (optional install)
- `systemd/model-ports-firewall.service`, `scripts/model-ports-firewall.sh` — let only named LAN hosts reach the model ports
- `../models/server-seats.tsv` — the seats this server serves: `num_ctx`, `num_gpu`, the base of a derived model, and
  the GGUF's `sha256`. Candidate seats are commented out until they are probed on this host.
- `scripts/llamacpp-check.sh` (+ `llamacpp_check.py`) — checks `llamacpp/models.ini` against that list (pinned file,
  `c` equal to `num_ctx`, one slot, the CPU seat). `--url http://localhost:8090` checks the running server;
  `--weights-container llamacpp-server` checks that each seat's GGUF is under `/models` (`--hash` re-hashes it). Run it
  after changing the list or the preset.
- `scripts/llamacpp-auth.sh` — the API-key helper the other scripts source
- `scripts/llamacpp-window.sh` — open, watch and close an unattended window ([docs/unattended-window.md](../docs/unattended-window.md))
- `scripts/llamacpp-soak.sh` — the llama.cpp trial's soak
- `scripts/startup.sh`, `scripts/stop.sh`, `scripts/status.sh` — start, stop, and check the engine

The Ollama-era files (`docker/docker-compose.yml`, `systemd/ollama-server.service`, `scripts/install-model.sh`,
`scripts/bake-models.sh`, `models/catalog.tsv` and `catalog.sh`) were deleted on 2026-11-21; they are in git history.

## Notes

- Context: each section of `llamacpp/models.ini` sets `c` explicitly, and it must equal `num_ctx` in
  `../models/server-seats.tsv` and `limit.context` in `opencode/global/opencode.jsonc` (`llamacpp-check.sh` and
  `tests/check_config_drift.py` check it).
- Tool-calling on this host was first probed 2026-10-12 on Ollama 0.34.3 (`tests/results/toolcalls-summary.tsv`, host
  `server`); the llama.cpp probes are hypothesis H3 in [docs/llamacpp-trial.md](../docs/llamacpp-trial.md). Re-probe
  after any llama.cpp build change.
- Access, the `sudo` rule and the `~/HomeLab` layout: [docs/network-topology.md](../docs/network-topology.md) → "SSH access".
- Files copied from Windows lose the exec bit — run `./make-executable.sh` after any scp.
