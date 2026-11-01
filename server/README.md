# Server (Ubuntu)

Scripts and configs for the Ubuntu development server — the primary Ollama node.

## Hardware

- AMD Ryzen 7 3700X (8c/16t)
- **RTX 4070 Ti Super (16 GB VRAM, Ada, CUDA)** — replaced a GTX 1070 in Sep 2026
- **32 GB DDR4 (Corsair Vengeance LPX)** — up from 16 GB
- More detail in [docs/hardware.md](../docs/hardware.md)

## What Runs Here

- **Qwen 2.5 Coder 7B / 14B** — autocomplete + coding via Docker + NVIDIA Container Toolkit
- **DeepSeek-R1 14B, Qwen3 8B/14B** — reasoning (profile-dependent)
- **General / creative / embeddings** — `dev-full`/`dev-embeddings` profiles
- **OpenCode CLI** — driven from WezTerm on the desktop over SSH

## Quick Start

```bash
# 1. Pick a profile (from the dev-docs root — .env is auto-sourced)
cd /path/to/dev-docs
source profiles/dev-workflow-server.sh

# 2. Install the profile's model groups (uses models/catalog.tsv)
./server/scripts/install-model.sh --profile

# 3. Start services
./server/scripts/startup.sh

# 4. Check status (GPU + API + catalog installed-vs-planned)
./server/scripts/status.sh
```

## Startup Methods

| Method | When to use |
|--------|-------------|
| `docker compose` | Default. Good for dev, easy to tear down. |
| `systemd` | Persistent across reboots, auto-restart on crash. |

`startup.sh` auto-detects: if the systemd unit is installed (`ollama-server.service`),
it uses `systemctl`; otherwise it falls back to `docker compose up -d`.

## Files

- `docker/docker-compose.yml` — Ollama container stack, pinned to 0.34.3 and aligned with the desktop's measured setup
  (flash attention, `q8_0` KV cache, NUM_PARALLEL=1, MAX_LOADED_MODELS=2, keep-alive 4h, default CONTEXT_LENGTH=16384)
- `docker/.env.example` — copy to `.env` and fill in values
- `systemd/ollama-server.service` — systemd unit (optional install; E2E via stop/startup)
- `scripts/install-model.sh` — catalog-aware model installer (`--list`, `--info`, `--ctx`, `--profile`, `--dry-run`)
- `../models/server-seats.tsv` — the seats this server serves: `num_ctx`, `num_gpu`, the base of a derived model, and
  the desktop copy's weights `sha256`. Candidate seats are commented out until they are probed on this host.
- `scripts/llamacpp-check.sh` — checks `llamacpp/models.ini` against that list (pinned blob, `c` equal to `num_ctx`,
  one slot, the CPU seat). `--url http://localhost:8090` checks the running server; `--weights-container
  llamacpp-server` checks that each seat's blob is really in Ollama's volume (`--hash` re-hashes it: about 30 s for all
  four seats) and says how to pull a missing one. Run it after changing the list or the preset. Since Phase 3
  (2026-11-01) it replaces `bake-models.sh` on the live path.
- `scripts/bake-models.sh` — the Ollama engine only (its container is stopped): pulls a missing seat, bakes `num_ctx`
  into the desktop's tag (plus the CPU-pinned 3b companion), reads the value back and compares the weights blob with
  the desktop's (`--dry-run`, `--only <tag>`, `--no-pull`). Kept for a rollback until Phase 6.
- `scripts/startup.sh` — bring services online
- `scripts/stop.sh` — stop services
- `scripts/status.sh` — GPU (`nvidia-smi`), API, loaded-model context, catalog gaps

## Notes

- Under Ollama (the rollback engine since Phase 3): the server honors `OLLAMA_CONTEXT_LENGTH` (unlike the Windows Ollama app), so
  un-baked tags serve at the env default (16384). Seats get their own `num_ctx` from
  `bake-models.sh` under the **same tag** as on the desktop, so one `opencode.jsonc`
  limit and one `tests/run-tasks-models.tsv` row hold on both hosts. Change a number
  in `bake-models.sh`, `desktop/scripts/startup.ps1` (`$contextModels`) and the
  `limit.context` of both OpenCode provider blocks together.
- Tool-calling on this host was first probed 2026-10-12 on Ollama 0.34.3
  (`tests/results/toolcalls-summary.tsv`, host `server`). Re-probe after any version change.
- Access, the `sudo` rule and the `~/HomeLab` layout: [docs/network-topology.md](../docs/network-topology.md) → "SSH access".
- Files copied from Windows lose the exec bit — run `./make-executable.sh` after any scp.