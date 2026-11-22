# Profiles

A profile is a sourced bash file in `profiles/` that picks which tiers are online, what to install where, and what OpenCode uses. One per shell. History: [archive/profiles-history.md](archive/profiles-history.md).

```bash
source profiles/dev-workflow-server-llamacpp.sh   # or: bash profiles/select-model.sh (menu of live profiles)
```

Windows: `opencode <short-name>` from any PowerShell after `install-opencode-profiles.ps1`, or `.\desktop\scripts\opencode.ps1 -Profile <name>`. Terms: [glossary](glossary.md).

## Live profiles (2)

Every local seat is a llama-server seat: Ollama was removed from the fleet on 2026-11-21, and the desktop runs no models (it is the OpenCode client and the harness run host).

| Profile | Main seat / small model | Host | Use when |
|---|---|---|---|
| `dev-workflow-server-llamacpp` **(default)** | `llamacpp-server/qwen3.6:35b-a3b-coding` @64k / `…/qwen2.5-coder-3b-cpu` | server (llama.cpp, port 8090) | everyday work; needs the llama.cpp stack up |
| `dev-node3` | `llamacpp-node3/qwen3:8b` / `llamacpp-server/qwen2.5-coder-3b-cpu` | node3 (llama.cpp) | work on the 3080 FE, or the server is down; falls back to the server's `qwen3:8b` without `NODE3_IP` |

`tests/test-profiles.ps1` checks each against an intent manifest (purpose, tier flags, main/small model, main seat tool-capable). The last full run on record (116 PASS, 0 FAIL, 0 WARN, 2 SKIP, 2026-10-12) was of the six Ollama-era live profiles; re-run it for the current two.

**Every main seat must pass the tool-call probe.** A coder or reasoner in an agent seat describes edits it never made. Failing models carry `"tool_call": false` in the OpenCode config, and `test-profiles.ps1` FAILs a profile whose main seat is not tool-capable. Details: [tool-calling.md](tool-calling.md).

## Parked profiles (1, in `profiles/parked/`)

Correct, not in daily use. Bring-back procedure: [`profiles/parked/README.md`](../profiles/parked/README.md). Probe a server model before seating it: `.\tests\test-toolcalls.ps1 -Engine llamacpp -EngineHost http://SERVER_IP:8090 -Model <tag>`.

| Profile | Purpose | Main seat |
|---|---|---|
| `dev-go-only` | Hosted models only, through OpenCode Go | Go default |

The six other parked profiles (`dev-quick`, `dev-coder`, `dev-server-all`, `dev-local-only`, `dev-embeddings`, `dev-full`) and the Ollama-era live profiles (`dev-workflow-server`, `dev-workflow-quality`, `dev-workflow-resident`, `dev-desktop-only`) were deleted on 2026-11-21 with Ollama: they named Ollama-only tags or desktop seats. They are in git history and [archive/profiles-history.md](archive/profiles-history.md).

## What every profile does

| Step | Detail |
|---|---|
| Loads `.env` | From the repo root (`set -a && source … && set +a`) |
| Tier toggles | `DEV_TIERS_{SERVER,DESKTOP,GO,NODE3}`, read by the profile menu and the launcher's report |
| OpenCode defaults | `OPENCODE_MODEL`, `OPENCODE_SMALL_MODEL`, per-host base URLs |

A profile installs nothing. What a host serves is its router preset (`server/llamacpp/models.ini`, `node3/llamacpp/models.ini`); adding a model: [reference/config.md](reference/config.md) → "Adding a model".

No live profile starts the Postgres + Redis stack (`desktop/docker`); run `.\desktop\scripts\docker-stack.ps1 up` when a project needs it.

## Environment variables

| Variable | Meaning | Set by |
|---|---|---|
| `DEV_TIERS_SERVER` / `_DESKTOP` / `_GO` / `_NODE3` | Which tiers the profile uses (NODE3 needs `NODE3_IP`); `_DESKTOP` is always false now | all profiles |
| `OPENCODE_MODEL` / `OPENCODE_SMALL_MODEL` | Default main / small model | most profiles |
| `LLAMACPP_SERVER_BASE_URL` | `llamacpp-server` endpoint (`http://SERVER_IP:8090/v1`). `{env:…}` has no fallback, so every live profile exports it | all live profiles |
| `LLAMACPP_NODE3_BASE_URL` | `llamacpp-node3` endpoint (`http://NODE3_IP:8090/v1`; node3's llama-server binds 127.0.0.1 until its LAN firewall rule, [node3/README.md](../node3/README.md)) | all live profiles |
| `LLAMACPP_SERVER_SSH` | ssh host for the harness's llama.cpp placement check (default `server`) | all live profiles |

`dev-node3` activates when `NODE3_IP` (or `LLAMACPP_NODE3_BASE_URL`) is set; without either the profile warns and falls back to the server's `qwen3:8b`.

## VRAM budgets are measured, not file sizes

A GGUF's size on disk is not its footprint: runtime adds KV cache and compute buffers (1 to 3 GB more). `qwen3.6` (a 21.7 GB file) is larger than the server's 16 GB card, so its expert layers spill to the server's CPU (`n-cpu-moe` in `server/llamacpp/models.ini`) and its companion `qwen2.5-coder-3b-cpu` runs on the CPU. Verify any change on the running server (`./server/scripts/status.sh`, `nvidia-smi`). Per-model measurements: [hardware.md](hardware.md).

## Plan toggle is not `/plan`

| | Plan/Build toggle (bottom left) | `/plan <scope>` |
|---|---|---|
| Does | Gates tool permissions for the current model | Runs on the main agent and writes `docs/implementation-tasks.md` |
| Switches model | No | No |
| Writes the task file | Never (no write tools in Plan mode) | Yes |

Then tell the main seat: `execute task #N from docs/implementation-tasks.md`. Check the plan's `file:line` claims before acting; in a verified run two of three interpretations were inverted ([troubleshooting](troubleshooting.md)).

## Tools are scoped per project, not per profile

Profiles choose models only. Every MCP tool schema and skill description rides in every request (all of them enabled measured 46,505 tokens against a 16k model).

| Layer | Contains |
|---|---|
| Global (`opencode/global/opencode.jsonc`) | zero MCP servers; skills `frontend-design`, `ui-ux-pro-max` |
| Project (`<project>/opencode.jsonc`) | whatever it needs; merges over global, `{ "enabled": false }` switches off an inherited server; skills by path, never copied |

Template with every option commented: `opencode/project-override/opencode.jsonc`.
