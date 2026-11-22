# Config: seats, adding a model, profiles, OpenCode, sync

> Moved verbatim from `AGENTS.md` on 2026-10-26 (the AGENTS.md split); no facts were dropped. Dated statements keep the date they were written with. **Rewritten for a llama.cpp-only fleet on 2026-11-22:** Ollama was removed on 2026-11-21, and with it the model catalog (`models/catalog.tsv`, `catalog.sh`), `install-model.sh`, `bake-models.sh` and the desktop's `startup.ps1` / `models.ps1`. Their old text is in git history.

## What each host serves

llama.cpp (`llama-server`, router mode) is the only local engine. The desktop runs no models; it is the OpenCode client and the harness run host.

| Host | Engine | What it serves | Weights |
|---|---|---|---|
| server | Docker, `server/docker/docker-compose.llamacpp.yml`, port 8090 | the sections of `server/llamacpp/models.ini`, each pinned by a row of `models/server-seats.tsv` | GGUF files in the server's `~/models` (the container's `/models`) |
| node3 | native `llama-server` (b11562), `node3/llamacpp/models.ini`, 127.0.0.1:8090 until its LAN firewall rule | `qwen3:8b`, and `qwen3.6:35b-a3b-coding` on demand | GGUF files on node3 ([node3/README.md](../../node3/README.md)) |

Three places must agree for each server seat, and `./server/scripts/llamacpp-check.sh` plus `tests/check_config_drift.py` check them:

| Where | What |
|---|---|
| `server/llamacpp/models.ini` | a `[<tag>]` section (plus `alias = <tag>` when the tag has a `:`), `model = /models/<file>.gguf`, an explicit `c`, the sampling keys |
| `models/server-seats.tsv` | `tag num_ctx num_gpu from weights source note`: `num_ctx` = the section's `c`, `weights` = the GGUF's `sha256:`, `source` = `import-server` |
| `opencode/global/opencode.jsonc` | the `llamacpp-server` provider's model entry, `limit.context` = `num_ctx`, `tool_call` honest (the probe decides) |

**Embedding models.** `nomic-embed-text` and `mxbai-embed-large` were Ollama-only (pulled from its registry, consumed via `/api/embeddings`) and went with it on 2026-11-21. Nothing in the fleet uses embeddings today. Future embedding use would be a llama-server seat started with `--embedding` ("restrict to only support embedding use case", per llama.cpp's [server README](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/server/README.md), read 2026-11-22; in the preset, a section with `embedding = true`, since preset keys are the flags without their dashes), which serves the OpenAI-compatible `/v1/embeddings`; it would get its own `server-seats.tsv` row, and no chat entry in `opencode.jsonc` (it has no chat endpoint).

## Adding a model

On the server:

1. **Copy the GGUF** into the server's `~/models` (the `/models` mount) and hash it: `sha256sum ~/models/<file>.gguf`. A different file is a different model, so its results are a new era.
2. **Add a section** to `server/llamacpp/models.ini`, keeping that file's contracts (its header): the section name is the tag, with `alias = <tag>` if the tag has a `:`; `model = /models/<file>.gguf`; an explicit `c`; the sampling the model's card recommends.
3. **Add a row** to `models/server-seats.tsv`: the tag, `num_ctx` = `c`, `num_gpu` (`0` for a CPU seat, else `-`), `from` (`-`), `weights` = `sha256:<hash>`, `source` = `import-server`, a note.
4. **Register it** in the `llamacpp-server` provider of `opencode/global/opencode.jsonc` with `limit.context` = `c`, then stage it with `.\desktop\scripts\sync-opencode.ps1`.
5. **Restart and check** on the server: `./server/scripts/stop.sh && ./server/scripts/startup.sh`, then `./server/scripts/llamacpp-check.sh --url http://localhost:8090 --weights-container llamacpp-server --hash`.
6. **Probe it** before seating it as a main model or tool-using subagent, and seat it only if it PASSes:
   `.\tests\test-toolcalls.ps1 -Engine llamacpp -EngineHost http://SERVER_IP:8090 -Model <tag>`.

`./server/scripts/status.sh` shows the engine, its restart policy, the GPU and the seats; `./server/scripts/startup.sh` and `./server/scripts/stop.sh` start and stop it. node3's preset is `node3/llamacpp/models.ini`; its steps are in [node3/README.md](../../node3/README.md).

## Profiles (`profiles/dev-*.sh`)

Each profile is sourced bash that (1) loads `.env` from repo root via `set -a && source "$DEVDOCS_ENV" && set +a`, then (2) exports tier toggles + OpenCode defaults. It installs nothing:

- `DEV_TIERS_SERVER/DESKTOP/GO/NODE3` — true/false, read by the profile menu and the launcher's report (`server/scripts/startup.sh` skips when `DEV_TIERS_SERVER` is not `true`). `DEV_TIERS_DESKTOP` is always false: the desktop runs no models.
- `OPENCODE_MODEL` / `OPENCODE_SMALL_MODEL` — consumed by OpenCode config via `{env:...}`.
- `LLAMACPP_SERVER_BASE_URL`, `LLAMACPP_NODE3_BASE_URL` — one host per OpenCode provider; `LLAMACPP_SERVER_SSH` — the ssh host the harness's placement check uses.

Live profiles are `dev-workflow-server-llamacpp` (default) and `dev-node3`; `dev-go-only` is parked ([docs/profiles.md](../profiles.md)). On Windows, launch through `.\desktop\scripts\opencode.ps1 -Profile <name>` or the `opencode <short-name>` shortcuts (`install-opencode-profiles.ps1`); in Git bash, `source profiles/<name>.sh`. `select-model.sh` is an interactive fzf picker that discovers `profiles/*.sh` dynamically, so it always lists exactly the live profiles and nothing parked.

## OpenCode config

- Template lives at `opencode/global/opencode.jsonc`; the live config is `~/.config/opencode/opencode.jsonc` on each machine. Edit the template, then stage it with `sync-opencode.ps1` (below; local only).
- Providers are split one-per-host: `llamacpp-server` and `llamacpp-node3` (`{env:LLAMACPP_*_BASE_URL}`, since 2026-10-16), plus the hosted `opencode-go`. The `ollama-*` providers and `llamacpp-desktop` were removed on 2026-11-21 with Ollama. Model ID format: `llamacpp-server/qwen3.6:35b-a3b-coding` (the part after `/` is the preset's section name). **Every live profile exports `LLAMACPP_SERVER_BASE_URL`** (and `LLAMACPP_SERVER_SSH`, the ssh host the harness's placement check uses), because `{env:...}` has no fallback.
- The global `mcp` block is **empty on purpose**. Every MCP server's full tool schema rides in every request's system prompt; the five that used to live here (`vercel`, `render`, `docker`, `browser`, `postgres` — ~105 tools) were most of a 46,505-token preamble that a 16k local model cannot hold. Servers now go in the **project's** `opencode.jsonc`, which deep-merges over global (`{ "enabled": false }` switches off an inherited one). Template with all five commented and ready: `opencode/project-override/opencode.jsonc`.
- Skills are scoped the same way: global ships only `frontend-design` + `ui-ux-pro-max`; a project pulls in more by path (`"skills": { "paths": ["M:/Projects/dev-docs/skills/vercel"] }`) — referenced in place, never copied.
- API keys go in `~/.config/opencode/.secrets/*` (plaintext files referenced via `{file:...}` substitution) — never in `.env` or the config. `.env` only holds IPs/SSH user and is git-ignored. **`{file:...}` refs are resolved at config load** — a referenced path that doesn't exist → config is invalid and OpenCode won't start. Create placeholder files first.
- **Two plugins are installed for daily use** (the `plugin` array of the template, both referenced in place from this checkout): `compaction-continue.js` (2026-10-05) and `read-budget.js` (2026-10-17). opencode 2.x skips both (a configured plugin must be a directory); the 2.x read-budget is the directory `opencode/plugins/read-budget/` (2026-11-21), which the template's 2.x `plugins` list takes at the cutover (`docs/opencode-2-migration.md`, step 5.1). The template also sets `tool_output.max_bytes` (shell output per call, 16384; an undocumented key that `opencode debug config` keeps and a misspelling silently drops). Run JSONs from 2026-10-17 on carry `readBudget`, a new era.
- Agents and commands are templates in `opencode/agents/*.md` and `opencode/commands/*.md`; they are staged to the live config by `sync-opencode.ps1`. **Agents/commands/config are read at session start — restart any running OpenCode after syncing.**

## Sync pipeline (desktop → the world)

| Script | What it does |
|---|---|
| `.\desktop\scripts\sync-opencode.ps1 [-Push <machine> [-Secrets a,b] [-RemoteRepoRoot <path>]]` | **Local by default (since 2026-10-19; no network, no `.env`):** stage `opencode/global/opencode.jsonc` + `agents/` + `commands/` → `~/.config/opencode/` (`-Template` is a no-op alias). The template's plugin paths carry a placeholder token that staging fills with this checkout's `file:///` URL (`desktop/scripts/opencode-template.ps1`). A changed live config is backed up as `opencode.jsonc.bak-<stamp>` with a diff summary; identical = no write. Then `opencode debug config` is run and every plugin path checked (warnings only). **Copying is opt-in:** `-Push <machine>` only for a `machines.tsv` row with the `opencode-client` role (else exit 1, nothing sent; host/user from `.env`, read only then), `-Secrets` only with `-Push` and only the named `.secrets/` files, never "all". Down host → warning, exit 0. Guard: `tests/test-sync-opencode.ps1`. |
| `.\desktop\scripts\sync-skills.ps1 [-Local\|-Server\|-Scope global\|all\|-Prune…]` | Deploy vendored skills (flattened `skills/<source>/<skill>/` → `~/.config/opencode/skills/<skill>/`) + commands + agents. **Default `-Scope global` deploys only `$GLOBAL_SKILL_SOURCES`** (`frontend-design`, `ui-ux-pro-max`); `vercel`/`render` stay project-scoped via `skills.paths`. Add `-Prune` when narrowing scope or the old skills stay behind and the preamble never shrinks. |
| `.\desktop\scripts\sync-wezterm.ps1` | Copy `wezterm/wezterm.lua` → `C:\Users\<you>\.wezterm.lua` (WezTerm loads this exact path). |
| `.\desktop\scripts\import-claude-skills.ps1` | Re-vendor skills/agents/commands from the local Claude Code plugin install into `skills/`, `opencode/agents/`, `opencode/commands/`. Provenance + licenses in `claude/README.md`. |

### Desktop Docker — dev environments (not prod, CPU-only)

Docker Desktop on the desktop runs **dev environments only**: a local service
stack (Postgres + Redis) and project devcontainers/sandboxes. **Containers never
get the GPU** — `C:\Users\<username>\.wslconfig` sets `gpuSupport=false` (the WSL
ConfigureGpu workaround), and nothing in a container should try to run a model
(the desktop runs no models at all since 2026-11-21). `.wslconfig` also caps WSL
memory at `12GB`.

- Stack: `desktop/docker/docker-compose.yml` (Postgres 16 + Redis 7, bound to
  `127.0.0.1` only, memory-capped). Credentials in `desktop/docker/.env`
  (copy `.env.example`; `up` fails fast without `POSTGRES_PASSWORD`). Manage
  with `.\desktop\scripts\docker-stack.ps1 up|down|status|logs|restart`.
  Nothing starts it at login (the desktop `startup.ps1` that could was deleted
  on 2026-11-21); start it by hand when a project needs it.
- Devcontainers: shared base `dev/docker/dev.dockerfile` (node:22-bookworm +
  python3 (3.11) + build tools → tagged `dev-base:1` by
  `.\desktop\scripts\docker-base.ps1`). Project `.devcontainer/` live in the
  project repos (`M:\Projects\LFCbot`, `M:\TTRPG\A Story of Heroes and Villains`
  — the latter bakes Playwright chromium + deps). Use the `/devcontain` and
  `/sandbox` OpenCode commands, or `.\desktop\scripts\docker-sandbox.ps1`
  directly. Rule: `--rm` + `--memory` + `--cpus` on every throwaway; never
  mount secrets into containers.

Restart the consuming app after each: OpenCode (config/agents/commands), WezTerm (Lua).
