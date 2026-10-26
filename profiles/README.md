# Model Selection Profiles

A profile is a sourced bash script that exports tier toggles, model intent and
OpenCode defaults. Full reference: [docs/profiles.md](../docs/profiles.md).

## Quick start

```bash
source profiles/dev-workflow-server-llamacpp.sh     # load one profile into this shell
eval "$(bash profiles/select-model.sh --print)"     # or pick from a menu, then load it
```

`select-model.sh` runs in a child process, so on its own it can only print the
`source ...` line to run; `--print` makes that line `eval`-able. On Windows,
`opencode <profile>` (see `desktop/scripts/opencode-profiles.ps1`) loads a
profile for you, and dot-sourcing `profiles/dev-desktop-only.ps1` loads the
desktop-only one into PowerShell.

## Live profiles (6)

| Profile | Main seat | Host | Use when |
|---|---|---|---|
| `dev-workflow-server-llamacpp.sh` | qwen3.6 on llama.cpp | server | **Default** |
| `dev-workflow-server.sh` | qwen3.6 on Ollama | server | Same seat, Ollama engine |
| `dev-workflow-quality.sh` | qwen3.6 | desktop | Server down or in a trial window |
| `dev-workflow-resident.sh` | qwen3:8b + resident 7B coder | desktop | Lighter, latency-tuned seat |
| `dev-desktop-only.sh` / `.ps1` | qwen3:8b | desktop | Everything local, no server |
| `dev-node3.sh` | qwen3:8b | node3 | Third node (3080 FE) |

Seven server profiles are parked in [`parked/`](parked/README.md) (not
deprecated; bring-back procedure there).

## What a profile exports

| Variable | Read by |
|---|---|
| `DEV_TIERS_SERVER/DESKTOP/GO/NODE3` | `server/scripts/startup.sh`, `desktop/scripts/startup.ps1` |
| `DEV_SERVER_MODELS`, `DEV_DESKTOP_MODELS`, `DEV_NODE3_MODELS` | `install-model.sh --profile`, `models.ps1 -Profile`, and which models `startup.ps1` pulls |
| `OPENCODE_MODEL`, `OPENCODE_SMALL_MODEL` | OpenCode config via `{env:...}` |
| `OLLAMA_*_BASE_URL`, `LLAMACPP_*_BASE_URL`, `LLAMACPP_SERVER_SSH` | one provider per host; `{env:...}` has no fallback, so every live profile sets them |

`SERVER_IP`, `NODE3_IP` and `SSH_USER` come from `<repo>/.env` (copy
`.env.example`); each profile loads it itself.

## Custom profiles

```bash
cp profiles/dev-workflow-server.sh profiles/dev-experiment.sh
# edit DEV_TIERS_*, DEV_*_MODELS and OPENCODE_*; add its intent to tests/test-profiles.ps1
```
