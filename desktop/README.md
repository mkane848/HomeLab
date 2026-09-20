# Desktop (Windows 11)

Scripts and configs for the personal desktop machine — the native-Vulkan Ollama node.

## Hardware

- AMD Ryzen 7 5800X3D
- AMD Radeon RX 6800 XT (16 GB VRAM, **Vulkan** — gfx1030 is unsupported by the Windows HIP SDK, so ROCm is permanently unavailable; see `docs/hardware.md`)
- Windows 11

## What Runs Here

- **Qwen3 14B / 8B** — the tool-capable agent seats (baked 32k ctx), driven via OpenCode
- **Qwen 2.5 Coder 3B/7B/14B, DeepSeek-R1 14B** — no-tools models for code text, explanation and review (derived `-16k`/`-32k` bakes, `num_ctx` baked in)
- **Qwen3-Coder 30B A3B, Qwen3.5 9B, DeepSeek-R1 0528 8B** — LM-Studio imports (not in `models/catalog.tsv`)
- **Ollama** — host for desktop-side model serving (native install, Vulkan backend)

## Quick Start

```powershell
# Pick a profile (from the dev-docs root)
#   bash profiles/select-model.sh   -- or source one (dev-local-only, dev-full, ...)

# Install the profile's model groups (uses models/catalog.tsv)
.\desktop\scripts\models.ps1 -Profile

# Start services (skips itself if DEV_TIERS_DESKTOP is false)
.\desktop\scripts\startup.ps1

# Or double-click startup.bat
```

## Model installer

`.\desktop\scripts\models.ps1` mirrors the server's `install-model.sh`, driven by `models/catalog.tsv`:

```powershell
.\desktop\scripts\models.ps1 -List                 # catalog summary
.\desktop\scripts\models.ps1 -List embed           # just one group
.\desktop\scripts\models.ps1 -Info glm4:9b         # one model detail
.\desktop\scripts\models.ps1 -Group reasoner       # install a group
.\desktop\scripts\models.ps1 -Profile              # install DEV_DESKTOP_MODELS
.\desktop\scripts\models.ps1 -Pull deepseek-r1:14b -Context 16384   # bake a <tag>-Nk derived model
.\desktop\scripts\models.ps1 -All -DryRun          # preview what "all" would install
```

## Files

- `scripts/startup.ps1` — start desktop Ollama + models, bake `deepseek-r1-16k`, honor `DEV_TIERS_DESKTOP`
- `scripts/startup.bat` — double-click launcher wrapper
- `scripts/status.ps1` — check what's running
- `scripts/models.ps1` — catalog-aware model installer (see above)
- `scripts/sync-wezterm.ps1` — deploy the WezTerm config (`..\..\wezterm\wezterm.lua`) to `C:\Users\<you>\.wezterm.lua`
- `scripts/sync-opencode.ps1` — deploy `opencode/global/opencode.jsonc` to `~/.config/opencode/`
- `scripts/pin-ollama-desktop.ps1` — **stop the native Ollama from silently
  auto-upgrading.** The server's Ollama is pinned by its image tag; the desktop
  is a native Inno Setup install whose tray app auto-updates, and upstream
  refused a switch to disable it (ollama/ollama#9404), so this adds a Windows
  Firewall outbound block on the updater. **Status: unverified — the desktop
  auto-updated 0.34.0 → 0.34.1 on 2026-09-19 anyway**, so either the rule was
  never applied or it did not hold. Check before relying on it, and re-run
  `tests\test-toolcalls.ps1` after any version move.
- `ollama/config.example.json` — Ollama config template (copy to `config.json`)

## Notes

- Per-model context is baked into each tag by `scripts/startup.ps1`
  (`$contextModels`) via a Modelfile — `OLLAMA_CONTEXT_LENGTH` is honoured on
  Windows since Ollama 0.34.0, but it is a single global default and cannot
  give per-model control. Keep `limit.context` in `opencode.jsonc` in sync
  with the bake.
- Vulkan only: no vLLM/TensorRT/CUDA tooling; use the server (CUDA) for those experiments.