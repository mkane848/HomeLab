# Profiles

A profile is a sourced bash file in `profiles/` that picks which tiers are online, what to install where, and what OpenCode uses. One per shell. History: [archive/profiles-history.md](archive/profiles-history.md).

```bash
source profiles/dev-workflow-server-llamacpp.sh   # or: bash profiles/select-model.sh (menu of live profiles)
```

Windows: `opencode <short-name>` from any PowerShell after `install-opencode-profiles.ps1`, or `.\desktop\scripts\opencode.ps1 -Profile <name>`. Terms: [glossary](glossary.md).

## Live profiles (6)

| Profile | Main seat / small model | Host | Use when |
|---|---|---|---|
| `dev-workflow-server-llamacpp` **(default)** | `llamacpp-server/qwen3.6:35b-a3b-coding` @64k / `…/qwen2.5-coder-3b-cpu` | server (llama.cpp, port 8090) | everyday work; needs the llama.cpp stack up |
| `dev-workflow-server` | `ollama-server/qwen3.6:35b-a3b-coding` @64k / `…/qwen2.5-coder-3b-cpu` | server (Ollama) | the same seat on Ollama |
| `dev-workflow-quality` | `qwen3.6:35b-a3b-coding` @64k / `qwen2.5-coder-3b-cpu` | desktop | server down or in a trial window |
| `dev-workflow-resident` | `qwen3:8b` @32k / `qwen2.5-coder:7b` | desktop | you want the 7B coder resident for code text; survives gaming |
| `dev-desktop-only` | `qwen3:8b` / `qwen2.5-coder:7b` | desktop | plain local console |
| `dev-node3` | `qwen3:8b` (node3) / `qwen2.5-coder:7b` (server) | node3 | general + embed work on the 3080 FE |

`tests/test-profiles.ps1` checks each against an intent manifest (purpose, tier flags, main/small model, main seat tool-capable). Last full run on record: 116 PASS, 0 FAIL, 0 WARN, 2 SKIP (2026-10-12, node3 unreachable).

**Every main seat must pass the tool-call probe.** A coder or reasoner in an agent seat describes edits it never made. Failing models carry `"tool_call": false` in the OpenCode config, and `test-profiles.ps1` FAILs a profile whose main seat is not tool-capable. Details: [tool-calling.md](tool-calling.md).

## Parked profiles (7, in `profiles/parked/`)

Correct, not deprecated: they target the down server. Bring-back procedure: [`profiles/parked/README.md`](../profiles/parked/README.md). Probe a server model before seating it: `.\tests\test-toolcalls.ps1 -Model <tag> -OllamaHost http://SERVER_IP:11434`.

| Profile | Purpose | Installs | Main seat |
|---|---|---|---|
| `dev-quick` | Fastest local loop, autocomplete only | Server: `autocomplete` | `ollama-server/qwen3:8b` |
| `dev-coder` | Heavy coding on the server's 14B | Server: `coder` | `ollama-server/qwen3:8b` |
| `dev-server-all` | Everything on the server, desktop idle | Server: `autocomplete coder reasoner` | `ollama-server/qwen3:8b` |
| `dev-local-only` | Zero cloud spend | Server: `autocomplete`; Desktop: `reasoner` | `ollama-desktop/qwen3:8b` |
| `dev-embeddings` | Semantic-search work | Server: `autocomplete embed` | `ollama-server/qwen3:8b` |
| `dev-go-only` | Try cloud models via OpenCode Go | Server: `autocomplete` | Go default |
| `dev-full` | Everything online | Server: `coder reasoner general creative embed`; Desktop: `reasoner` | Go default |

## What every profile does

| Step | Detail |
|---|---|
| Loads `.env` | From the repo root (`set -a && source … && set +a`) |
| Tier toggles | `DEV_TIERS_{SERVER,DESKTOP,GO,NODE3}`, read by the startup scripts |
| Install intent | `DEV_{SERVER,DESKTOP,NODE3}_MODELS` (catalog tags or groups), read by `install-model.sh --profile` / `models.ps1 -Profile` |
| OpenCode defaults | `OPENCODE_MODEL`, `OPENCODE_SMALL_MODEL`, per-host base URLs |

No live profile starts the Postgres + Redis stack (`desktop/docker`); run `.\desktop\scripts\docker-stack.ps1 up` when a project needs it (it costs memory the `qwen3.6` pair needs).

## Environment variables

| Variable | Meaning | Set by |
|---|---|---|
| `DEV_TIERS_SERVER` / `_DESKTOP` / `_GO` / `_NODE3` | Which tiers start at boot or are available (NODE3 needs `NODE3_IP`) | all profiles |
| `DEV_SERVER_MODELS` / `DEV_DESKTOP_MODELS` / `DEV_NODE3_MODELS` | Catalog tags/groups to install per host | all profiles |
| `OPENCODE_MODEL` / `OPENCODE_SMALL_MODEL` | Default main / small model | most profiles |
| `OLLAMA_SERVER_BASE_URL` | `ollama-server` endpoint | server profiles use `http://SERVER_IP:11434/v1`; parked ones default to `localhost` |
| `OLLAMA_DESKTOP_BASE_URL` / `OLLAMA_NODE3_BASE_URL` | `ollama-desktop` / `ollama-node3` endpoints | desktop profiles / `dev-node3` |
| `LLAMACPP_SERVER_BASE_URL` | `llamacpp-server` endpoint (`http://SERVER_IP:8090/v1`). `{env:…}` has no fallback, so every live profile exports it | all live profiles |
| `LLAMACPP_DESKTOP_BASE_URL` / `LLAMACPP_NODE3_BASE_URL` | Reserved; no llama-server runs there yet | desktop profiles / `dev-node3` |
| `LLAMACPP_SERVER_SSH` | ssh host for the harness's llama.cpp placement check (default `server`) | all live profiles |

`dev-node3` activates when `NODE3_IP` is set in `.env`; without it the profile warns and falls back to a server-side default.

## VRAM budgets are measured, not catalog sizes

`catalog.tsv` `size_gb` is the GGUF on disk; runtime adds KV cache and compute buffers (1 to 3 GB more), and only ~14.8 of the desktop's 16 GB is usable. Measured with flash attention and a `q8_0` KV cache:

| Profile | Resident pair | VRAM |
|---|---|---|
| `dev-workflow-quality` | `qwen3.6` @64k + `qwen2.5-coder-3b-cpu` @16k | **12.51 GB** (of 21.13 total; the rest in RAM, 2.27 GB for the CPU 3b) |
| `dev-workflow-resident` | `qwen3:8b` @32k + `qwen2.5-coder-16k` @16k | 7.16 + 4.81 = **11.97 GB** |

`qwen3.6` is larger than the card, so the companion runs on the CPU (no evictions in three sessions; [main-seat-trial.md](main-seat-trial.md)). Verify any change with `curl :11434/api/ps` and expect both models listed. More: [hardware.md](hardware.md).

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
