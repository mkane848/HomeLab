# Desktop (Windows 11)

Scripts and configs for the personal desktop machine — the ROCm Ollama node.

## Hardware

- AMD Ryzen 7 5800X3D
- AMD Radeon RX 6800 XT (16 GB VRAM, ROCm)
- Windows 11

## What Runs Here

- **DeepSeek-R1 14B** — reasoning and planning via native AMD-ROCm Ollama (derived `deepseek-r1-16k`, num_ctx baked in)
- **Qwen 2.5 Coder 7B, GLM4 9B, embeddings** — pulled via `models.ps1`
- **Ollama** — host for desktop-side model serving

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
- `ollama/config.example.json` — Ollama config template (copy to `config.json`)

## Notes

- The Windows Ollama app **overrides** `OLLAMA_CONTEXT_LENGTH` (VRAM-based default),
  so high contexts are baked into derived models (e.g. `deepseek-r1-16k`) via a
  Modelfile — don't rely on the env var here.
- ROCm only: no vLLM/TensorRT; use the server (CUDA) for those experiments.