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
source profiles/dev-server-all.sh

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

- `docker/docker-compose.yml` — Ollama container stack (OLLAMA_HOST, CONTEXT_LENGTH=16384, NUM_PARALLEL=4, MAX_LOADED_MODELS=2)
- `docker/.env.example` — copy to `.env` and fill in values
- `systemd/ollama-server.service` — systemd unit (optional install; E2E via stop/startup)
- `scripts/install-model.sh` — catalog-aware model installer (`--list`, `--info`, `--ctx`, `--profile`, `--dry-run`)
- `scripts/startup.sh` — bring services online
- `scripts/stop.sh` — stop services
- `scripts/status.sh` — GPU (`nvidia-smi`), API, loaded-model context, catalog gaps

## Notes

- The server honors `OLLAMA_CONTEXT_LENGTH` (unlike the Windows Ollama app), so
  base tags serve at the env default; bake a derived `<tag>-Nk` only when you need
  a single model with more.
- Files copied from Windows lose the exec bit — run `./make-executable.sh` after any scp.