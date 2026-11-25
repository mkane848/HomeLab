# Start Here

From a cold machine to a working agent in OpenCode, with a check at each step. (Prefer VS Code? See [vscode.md](vscode.md).) Terms: [glossary](glossary.md).

**Status (2026-11-22):** llama.cpp (`llama-server`) is the only local engine; Ollama was removed from the fleet on 2026-11-21. The server serves the main seat. Default profile `dev-workflow-server-llamacpp`: `qwen3.6` @64k on the server's llama-server. You run OpenCode on the desktop, which runs no models; only the model is remote. Server down? Use `dev-node3` (`qwen3:8b` on node3's llama-server) or the parked hosted-only `dev-go-only`; there is no desktop fallback any more.

## The 30-second version

```powershell
cd <path-to-HomeLab-checkout>
.\desktop\scripts\opencode.ps1     # loads the default profile, launches OpenCode
```

Then type a request.

**First time on this machine** (once; the steps below assume it):

1. PowerShell 7 (`pwsh`) and OpenCode. No local engine is needed on the desktop.
2. Copy `.env.example` to `.env` at the repo root and fill in `SERVER_IP` (and the other hosts you have).
3. Create the key file the config points at, even if it is empty: `~/.config/opencode/.secrets/opencode-go-api-key`. OpenCode
   will not start while a `{file:...}` reference has no file ([opencode/README.md](../opencode/README.md)).
4. `.\desktop\scripts\sync-opencode.ps1` stages the config, agents and commands into `~/.config/opencode/`. Step 2b checks it.
5. The server's llama.cpp stack must be up for the default profile: on the server, `./server/scripts/status.sh`
   (start it with `./server/scripts/startup.sh`).

## Steps

| # | Do | Expect | If not |
|---|---|---|---|
| 1 | `curl.exe -s http://SERVER_IP:8090/health` | `{"status":"ok"}` | On the server: `./server/scripts/status.sh`, then `./server/scripts/startup.sh`; see [troubleshooting](troubleshooting.md) |
| 2 | `.\desktop\scripts\opencode.ps1` | `[opencode] profile=dev-workflow-server-llamacpp OPENCODE_MODEL=llamacpp-server/qwen3.6:35b-a3b-coding` | Check `.env` has `SERVER_IP` |
| 2b | `opencode debug config` | `"model"` = the profile's model, and a `limit` block on its provider entry | No `limit`: every request fails ([troubleshooting](troubleshooting.md)) |
| 3 | Ask: `Create a file at docs/_scratch.md containing the single line: it works` | `← Write docs/_scratch.md`, you approve, the file exists. Delete it | File claimed but missing: the model cannot call tools, see [tool-calling.md](tool-calling.md) |

Use `curl.exe`, not `curl`: in PowerShell `curl` aliases `Invoke-WebRequest`, which swallows `-s` and prompts for a Uri (Ctrl+C). The same trap exists for `wget`, `ls`, `rm`.

## Profiles in one screen

A profile is a shell script that only exports environment variables (`OPENCODE_MODEL`, `OPENCODE_SMALL_MODEL`, base URLs, `DEV_TIERS_*`). OpenCode's config reads them as `{env:OPENCODE_MODEL}`.

| Fact | Detail |
|---|---|
| Per shell | Sourcing in one terminal affects no other. `opencode.ps1` sources into its own process, then launches |
| Bare `opencode` | Falls back to Windows User-level env defaults. Use the wrapper |
| Switch | `.\desktop\scripts\opencode.ps1 -Profile dev-node3` |
| Short names | Run `.\desktop\scripts\install-opencode-profiles.ps1` once, then: |

```powershell
opencode server-llamacpp   # default: qwen3.6 on the server
opencode node3             # qwen3:8b on node3's llama-server
opencode node3 run "..."   # anything after the name goes to opencode
```

All profiles: [profiles.md](profiles.md).

## Context

A model's context is how many tokens it holds at once (prompt, files read and reply share it). On llama-server it is the `c` key of the model's section in the router preset (`server/llamacpp/models.ini`, node3's `node3/llamacpp/models.ini`), and it must equal `num_ctx` in `models/server-seats.tsv` and `limit.context` in `opencode/global/opencode.jsonc`; `tests/check_config_drift.py` and `server/scripts/llamacpp-check.sh` enforce that. The main seat serves 65536.

16k is too small to work in: the system prompt plus tool schemas measure 11,441 tokens, and with 4,096 reserved for output a 16k window leaves about 850 tokens.

## What's loaded, and what fits

The server runs llama-server in router mode: one model section loads on demand, and `GET http://SERVER_IP:8090/models` lists the seats and which are loaded (with the fleet key once the engine API keys are rolled out: [engine-api-keys.md](engine-api-keys.md); `/health` never needs one). Budget VRAM from the running server (`nvidia-smi` on the server, or `./server/scripts/status.sh`), not from file sizes. `qwen3.6` is larger than the 16 GB card, so its expert layers spill to the server's CPU (`n-cpu-moe` in the preset), and its companion `qwen2.5-coder-3b-cpu` runs on the CPU. VRAM tables and gaming limits for node3: [hardware.md](hardware.md).

## Tools: skills and MCP servers

Both cost tokens on **every** request. With everything on, the preamble measured 46,505 tokens (2026-09, before the engine switch) and requests died after five minutes. Now 11,441.

| Layer | Contains |
|---|---|
| Global (`opencode/global/opencode.jsonc`) | no MCP servers; skills `frontend-design`, `ui-ux-pro-max` |
| Project (`<project>/opencode.jsonc`) | what that project needs. Copy `opencode/project-override/opencode.jsonc`; `{ "enabled": false }` switches off an inherited server |

Point a project at skills in place, never copy: `"skills": { "paths": ["<checkout>/skills/vercel"] }`. Re-measure after any change by running a trivial request and reading the prompt token count llama-server logs for it (`docker logs llamacpp-server` on the server).

## When something looks wrong

Run `.\tests\test-profiles.ps1` first; expect `0 FAIL`. A SKIP is a host that did not answer.

| Symptom | Likely cause | Where |
|---|---|---|
| Agent claims an edit that didn't happen | Model can't call tools | [troubleshooting](troubleshooting.md) → "Agent 'says' it edited a file" |
| Request hangs minutes then fails | Preamble too big or missing `limit` | → "OpenCode request hangs ~5 minutes" |
| Model not in `/models` | Not registered in `opencode.jsonc` | → "Local model not in /models" |

## Where next

| I want to… | Read |
|---|---|
| Choose a profile | [profiles.md](profiles.md) |
| Plan, then execute | [tool-calling.md](tool-calling.md) → `/plan` |
| Know what runs where | [model-architecture.md](model-architecture.md) |
| Check VRAM facts | [hardware.md](hardware.md) |
| Add or change a model | [reference/config.md](reference/config.md) → "Adding a model" |
| Fix the server | [server-recovery-cpu-led.md](server-recovery-cpu-led.md) |
| Use VS Code | [vscode.md](vscode.md) |
| See what's open | [plan.md](plan.md) |
