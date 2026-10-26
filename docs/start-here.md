# Start Here

From a cold machine to a working agent in OpenCode, with a check at each step. (Prefer VS Code? See [vscode.md](vscode.md).) Terms: [glossary](glossary.md).

**Status (2026-10-26):** the server serves the main seat. Default profile `dev-workflow-server-llamacpp`: `qwen3.6` @64k on the server's llama.cpp. You still run OpenCode on the desktop; only the model is remote. Server down, or in a trial window? Use `dev-workflow-quality` (same seat on this desktop): `opencode quality`.

## The 90-second version

```powershell
cd <path-to-HomeLab-checkout>
.\desktop\scripts\startup.ps1      # starts desktop Ollama, bakes each model's context
.\desktop\scripts\opencode.ps1     # loads the default profile, launches OpenCode
```

Then type a request. Step 1 is only needed for the desktop fallback and VS Code.

## Steps

| # | Do | Expect | If not |
|---|---|---|---|
| 1 | `.\desktop\scripts\startup.ps1` | Prints a "Context contract" table matching `limit.context` in `opencode.jsonc` | `Get-Process ollama`; see [troubleshooting](troubleshooting.md) |
| 1b | `curl.exe -s http://localhost:11434/api/version` | The running version (desktop pinned to `0.34.3`) | A different version means it auto-updated: re-run `.\tests\test-toolcalls.ps1` before trusting any seat |
| 2 | `.\desktop\scripts\opencode.ps1` | `[opencode] profile=dev-workflow-server-llamacpp OPENCODE_MODEL=llamacpp-server/qwen3.6:35b-a3b-coding` | Check `.env` has `SERVER_IP` |
| 2b | `opencode debug config` | `"model"` = the profile's model, and a `limit` block on its provider entry | No `limit`: every request fails ([troubleshooting](troubleshooting.md)) |
| 3 | Ask: `Create a file at docs/_scratch.md containing the single line: it works` | `← Write docs/_scratch.md`, you approve, the file exists. Delete it | File claimed but missing: the model cannot call tools, see [tool-calling.md](tool-calling.md) |

Use `curl.exe`, not `curl`: in PowerShell `curl` aliases `Invoke-WebRequest`, which swallows `-s` and prompts for a Uri (Ctrl+C). The same trap exists for `wget`, `ls`, `rm`.

## Profiles in one screen

A profile is a shell script that only exports environment variables (`OPENCODE_MODEL`, `OPENCODE_SMALL_MODEL`, base URLs, `DEV_TIERS_*`). OpenCode's config reads them as `{env:OPENCODE_MODEL}`.

| Fact | Detail |
|---|---|
| Per shell | Sourcing in one terminal affects no other. `opencode.ps1` sources into its own process, then launches |
| Bare `opencode` | Falls back to Windows User-level env defaults (set by hand for the desktop seat). Use the wrapper |
| Switch | `.\desktop\scripts\opencode.ps1 -Profile dev-workflow-resident` |
| Short names | Run `.\desktop\scripts\install-opencode-profiles.ps1` once, then: |

```powershell
opencode server-llamacpp   # default
opencode server            # same seat on the server's Ollama
opencode quality           # desktop qwen3.6 + CPU 3b
opencode resident          # qwen3:8b + 7b coder
opencode desktop-only run "..."
```

Switching unloads desktop models the new profile does not use (`-KeepLoaded` keeps them). All profiles: [profiles.md](profiles.md).

## Context "baking"

A model's context is how many tokens it holds at once (prompt, files read and reply share it). Ollama has one global default, but models here need different sizes, so `startup.ps1` writes `PARAMETER num_ctx` into each model's Modelfile. Re-running is safe.

| `num_ctx` | Models |
|---|---|
| 65536 | `qwen3.6:35b-a3b-coding`, `qwen3-coder:30b-a3b`, `qwen3.5:9b`, `north-mini-code-1.0`, `laguna-xs-2.1`, `nemotron-3.5-lightning` |
| 32768 | `qwen3:14b`, `qwen3:8b`, `qwen2.5-coder:14b`, the devstral pair |
| 16384 | the rest |

16k is too small to work in: the system prompt plus tool schemas measure 11,441 tokens, and with 4,096 reserved for output a 16k window leaves about 850 tokens. The authoritative list is `$contextModels` in `startup.ps1`.

## What's loaded, and what fits

`curl.exe -s http://localhost:11434/api/ps` lists models in VRAM. If a second model does not fit, Ollama **evicts** the first: ~14 s to reload plus a lost prompt cache. Budget from `/api/ps`, never from `catalog.tsv` (real VRAM runs 1 to 3 GB higher; ~14.8 of 16 GB is usable).

| Seat (desktop) | Expect in `/api/ps` | Why |
|---|---|---|
| `dev-workflow-quality` | `qwen3.6` size 21.13 GB, vram 12.51 GB; `qwen2.5-coder-3b-cpu` vram 0 | `qwen3.6` is larger than the card, so the companion runs on the CPU (`num_gpu 0`). The pair leaves ~3.5 GB of 32 GB RAM, so the Docker dev stack does not start at login |
| `dev-workflow-resident` | `qwen3:8b` 7.16 GB + `qwen2.5-coder-16k` 4.81 GB | The only pair that survives gaming (available VRAM drops from 14.8 to 12.5 GiB with a game running) |

Benchmarks taken while gaming are meaningless; probe verdicts are still valid. VRAM tables and gaming limits: [hardware.md](hardware.md), [profiles.md](profiles.md).

## Tools: skills and MCP servers

Both cost tokens on **every** request. With everything on, the preamble measured 46,505 tokens; Ollama truncated it and requests died after five minutes. Now 11,441.

| Layer | Contains |
|---|---|
| Global (`opencode/global/opencode.jsonc`) | no MCP servers; skills `frontend-design`, `ui-ux-pro-max` |
| Project (`<project>/opencode.jsonc`) | what that project needs. Copy `opencode/project-override/opencode.jsonc`; `{ "enabled": false }` switches off an inherited server |

Point a project at skills in place, never copy: `"skills": { "paths": ["<checkout>/skills/vercel"] }`. Re-measure after any change by running a trivial request and reading `task.n_tokens` from the Ollama log.

## When something looks wrong

Run `.\tests\test-profiles.ps1` first; expect `0 FAIL`. A node3 install-intent WARN is a documented false positive; a SKIP is a host that did not answer.

| Symptom | Likely cause | Where |
|---|---|---|
| Agent claims an edit that didn't happen | Model can't call tools | [troubleshooting](troubleshooting.md) → "Agent 'says' it edited a file" |
| Request hangs minutes then fails | Preamble too big or missing `limit` | → "OpenCode request hangs ~5 minutes" |
| Everything got slow | Main model was evicted | → "Desktop is slow" |
| "AMD driver is too old" | ROCm unavailable on this GPU, permanently | → "ROCm not detected" |
| Model not in `/models` | Not registered in `opencode.jsonc` | → "Local model not in /models" |

## Where next

| I want to… | Read |
|---|---|
| Choose a profile | [profiles.md](profiles.md) |
| Plan, then execute | [tool-calling.md](tool-calling.md) → `/plan` |
| Know what runs where | [model-architecture.md](model-architecture.md) |
| Check VRAM facts | [hardware.md](hardware.md) |
| Add or change a model | [AGENTS.md](../AGENTS.md) → "Model catalog" |
| Fix the server | [server-recovery-cpu-led.md](server-recovery-cpu-led.md) |
| Use VS Code | [vscode.md](vscode.md) |
| See what's open | [roadmap.md](roadmap.md) |
