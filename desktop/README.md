# Desktop (Windows 11)

Scripts and configs for the personal desktop machine: the daily **OpenCode client** and the **harness run host**.
**It runs no models** (since 2026-11-21): Ollama was removed from the fleet that day, and the desktop's GPU has
unresolved crashes. Models are served by llama.cpp (`llama-server`) on the server and node3.

## Hardware

- AMD Ryzen 7 5800X3D
- AMD Radeon RX 6800 XT (16 GB VRAM; not used for models)
- Windows 11

It is also the gaming PC: check that no game is running before heavy work here.

## Quick Start

```powershell
cd <path-to-HomeLab-checkout>
.\desktop\scripts\opencode.ps1                     # default profile: qwen3.6 on the server's llama-server
.\desktop\scripts\opencode.ps1 -Profile dev-node3  # qwen3:8b on node3's llama-server
```

After `.\desktop\scripts\install-opencode-profiles.ps1` runs once, `opencode server-llamacpp` and `opencode node3`
work from any PowerShell window. Step-by-step first run: [docs/start-here.md](../docs/start-here.md).

## Files

- `scripts/opencode.ps1` — launch OpenCode with a profile's models (`-Profile <name>`)
- `scripts/opencode-profiles.ps1` + `scripts/install-opencode-profiles.ps1` — `opencode <profile>` from any PowerShell
- `scripts/opencode-standalone.ps1` — dot-sourced by `opencode.ps1`: OpenCode 2.x needs `--standalone` for a profile's env to reach it
- `scripts/opencode-template.ps1` — shared helpers for staging the config template
- `scripts/sync-opencode.ps1` — stage `opencode/global/opencode.jsonc` (+ agents, commands) into `~/.config/opencode/` on this machine, with a backup and a diff; `-Push <machine>` copies to another `opencode-client` machine (`machines.tsv`)
- `scripts/sync-skills.ps1` — deploy vendored skills to OpenCode
- `scripts/sync-wezterm.ps1` — deploy the WezTerm config (`..\..\wezterm\wezterm.lua`) to `C:\Users\<you>\.wezterm.lua`
- `scripts/import-claude-skills.ps1` — vendor Claude plugin skills into this repo
- `scripts/docker-stack.ps1`, `docker-base.ps1`, `docker-sandbox.ps1` — the CPU-only dev stack (Postgres + Redis), the shared dev base image and throwaway sandboxes ([docs/reference/config.md](../docs/reference/config.md) → "Desktop Docker")
- `scripts/run-planner.ps1`, `run-planner-local.ps1`, `make-planner-packs.py`, `planner_done.py` — experiment 3's planner step ([docs/planner-tests-experiment.md](../docs/planner-tests-experiment.md))
- `scripts/pull-household-backup.ps1` — copy the newest household tracker backup off the server

The Ollama-era scripts (`startup.ps1`, `startup.bat`, `models.ps1`, `status.ps1`, `pin-ollama-desktop.ps1`) and the
Ollama config template were deleted on 2026-11-21; they are in git history.
