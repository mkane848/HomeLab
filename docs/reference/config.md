# Config: catalog, installs, profiles, OpenCode, sync

> Moved verbatim from `AGENTS.md` on 2026-10-26 (the AGENTS.md split); no facts were dropped. Dated statements keep the date they were written with.

## Model catalog (single source of truth)

- `models/catalog.tsv` — every model we can run, tab-separated so both bash and PowerShell parse it. Columns: `tag  size_gb  class  ctx  groups  hosts  desc`.
  - `class`: `fit` (16GB VRAM), `edge` (tight), `offload` (needs system RAM).
  - `groups`: install groups `autocomplete coder reasoner general creative embed`.
  - `hosts`: eligible machines `server desktop node3` (`all` = any).
- `models/catalog.sh` — bash library. **Sourced, never executed.** Use `source models/catalog.sh` then `catalog_list`, `catalog_list <group>`, `catalog_field <tag> <col>`, `catalog_has_tag`, `catalog_groups`.
- To add a model: add a row to `catalog.tsv`; register it in the matching provider block of `opencode/global/opencode.jsonc` so it appears in OpenCode's `/models` after install; then stage + sync (below). **Probe it first** — `.\tests\test-toolcalls.ps1 -Model <tag>` — and only seat it as a main model or tool-using subagent if it PASSes.
- **Not every catalog row belongs in `opencode.jsonc`, and not every `opencode.jsonc` entry is in the catalog — both by design.** `nomic-embed-text` and `mxbai-embed-large` are embedding models: they have no chat endpoint, and registering them would offer them in `/models` as if you could talk to them. They live in the catalog (so `models.ps1 -Group embed` installs them) and are consumed directly via `/api/embeddings`. A tag registered on one host's provider but not another's is usually deliberate too (`gemma3:12b` is server-block only and unprobed; `qwen3:14b` is deliberately absent from the node3 block — tight on 10 GB). Conversely the three local-GGUF imports on desktop (`qwen3-coder:30b-a3b`, `qwen3.5:9b`, `deepseek-r1-0528:8b`) are registered but have no catalog row. A catalog↔config diff is not automatically a defect; check which of these three cases it is first.
- Serve context: server honors `OLLAMA_CONTEXT_LENGTH` (16384 default). Desktop bakes it (see Gotchas) — the catalog `ctx` and OpenCode model IDs assume the served number, so the client never over-promises.

## Installing models

- Server (Docker): `./server/scripts/install-model.sh <tag|group|all|--profile>`. `--profile` reads `DEV_SERVER_MODELS`. `--ctx N` creates a derived `<tag>-Nk` model with baked `num_ctx`. Runs `docker exec ollama-server ollama ...`. Seats are listed in `models/server-seats.tsv` and put into the desktop's shape by `./server/scripts/bake-models.sh` (`--dry-run`, `--only <tag>`, `--no-pull`): it pulls a missing seat, bakes `num_ctx` under the **same tag** as the desktop (qwen3.6 65536, `qwen3:8b` 32768, the 3b 16384, plus the CPU-pinned `qwen2.5-coder-3b-cpu`; the server half of `startup.ps1`'s `$contextModels`), reads the baked value back, and compares the weights blob with the desktop's recorded `sha256` (a different blob is a new era for that seat). The compose file pins Ollama 0.34.3 with flash attention, a `q8_0` KV cache, `NUM_PARALLEL=1` and a 4 h keep-alive, as on the desktop.
- Desktop (native, Vulkan): `.\desktop\scripts\models.ps1 -Pull <tags> | -Group <g> | -All | -Profile` (`-Profile` reads `DEV_DESKTOP_MODELS`), `-Context N` bakes a derived model, `-List` lists installed. `startup.ps1` auto-pulls missing bake targets and bakes a per-model `num_ctx` (65536 for `qwen3.5:9b`, `qwen3-coder:30b-a3b`, `north-mini-code-1.0`, `laguna-xs-2.1`, `qwen3.6:35b-a3b-coding` and `nemotron-3.5-lightning`; 32768 for `qwen3:14b`, `qwen3:8b`, `qwen2.5-coder:14b` and the devstral pair; 16384 for the rest, including `deepseek-r1:14b` with its baked `deepseek-r1-16k`/`-32k` aliases — see `$contextModels`), then derives `qwen2.5-coder-3b-cpu` from the 3b with `num_gpu 0` (`$derivedModels`; the quality profile's CPU companion).

## Profiles (`profiles/dev-*.sh`)

Each profile is sourced bash that (1) loads `.env` from repo root via `set -a && source "$DEVDOCS_ENV" && set +a`, then (2) exports tier toggles + model intent + OpenCode defaults:

- `DEV_TIERS_SERVER/DESKTOP/GO/NODE3` — true/false, read by `server/scripts/startup.sh` and `desktop/scripts/startup.ps1`.
- `DEV_SERVER_MODELS` / `DEV_DESKTOP_MODELS` — space-separated catalog tags/groups to install on each host.
- `OPENCODE_MODEL` / `OPENCODE_SMALL_MODEL` — consumed by OpenCode config via `{env:...}`.
- `OLLAMA_DESKTOP_URL`/`OLLAMA_DESKTOP_BASE_URL`, `OLLAMA_SERVER_BASE_URL`, `OLLAMA_NODE3_BASE_URL` — one host per OpenCode provider.

On Windows, load the profile into the current process: PowerShell `. \profiles\dev-desktop-only.ps1` (dot-source; sets process-scope env), or Git bash `source profiles/dev-desktop-only.sh`. There is no `lib/load-env.ps1` — `dev-desktop-only.ps1` is the only PowerShell wrapper. `select-model.sh` is an interactive fzf picker that discovers `profiles/*.sh` dynamically, so it always lists exactly the live profiles (currently six) and nothing parked.

## OpenCode config

- Template lives at `opencode/global/opencode.jsonc`; the live config is `~/.config/opencode/opencode.jsonc` on each machine. Edit the template, then stage it with `sync-opencode.ps1` (below; local only).
- Providers are split one-per-host: `ollama-server`, `ollama-desktop`, `ollama-node3` (a single ollama provider can't reach two hosts), and since 2026-10-16 `llamacpp-server`, `llamacpp-desktop`, `llamacpp-node3` (`{env:LLAMACPP_*_BASE_URL}`; only the server runs a llama-server so far). Model ID format: `ollama-server/qwen2.5-coder:7b`. **Every live profile exports `LLAMACPP_SERVER_BASE_URL`** (and `LLAMACPP_SERVER_SSH`, the ssh host the harness's placement check uses), because `{env:...}` has no fallback.
- The global `mcp` block is **empty on purpose**. Every MCP server's full tool schema rides in every request's system prompt; the five that used to live here (`vercel`, `render`, `docker`, `browser`, `postgres` — ~105 tools) were most of a 46,505-token preamble that a 16k local model cannot hold. Servers now go in the **project's** `opencode.jsonc`, which deep-merges over global (`{ "enabled": false }` switches off an inherited one). Template with all five commented and ready: `opencode/project-override/opencode.jsonc`.
- Skills are scoped the same way: global ships only `frontend-design` + `ui-ux-pro-max`; a project pulls in more by path (`"skills": { "paths": ["M:/Projects/dev-docs/skills/vercel"] }`) — referenced in place, never copied.
- API keys go in `~/.config/opencode/.secrets/*` (plaintext files referenced via `{file:...}` substitution) — never in `.env` or the config. `.env` only holds IPs/SSH user and is git-ignored. **`{file:...}` refs are resolved at config load** — a referenced path that doesn't exist → config is invalid and OpenCode won't start. Create placeholder files first.
- **Two plugins are installed for daily use** (the `plugin` array of the template, both referenced in place from this checkout): `compaction-continue.js` (2026-10-05) and `read-budget.js` (2026-10-17). The template also sets `tool_output.max_bytes` (shell output per call, 16384; an undocumented key that `opencode debug config` keeps and a misspelling silently drops). Run JSONs from 2026-10-17 on carry `readBudget`, a new era.
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
ConfigureGpu workaround), so Ollama stays native (Vulkan backend) on the host and
nothing in a container should try to run a model. `.wslconfig` also caps WSL
memory at `12GB` so sandboxes can't starve host Ollama.

- Stack: `desktop/docker/docker-compose.yml` (Postgres 16 + Redis 7, bound to
  `127.0.0.1` only, memory-capped). Credentials in `desktop/docker/.env`
  (copy `.env.example`; `up` fails fast without `POSTGRES_PASSWORD`). Manage
  with `.\desktop\scripts\docker-stack.ps1 up|down|status|logs|restart`.
- `desktop/scripts/startup.ps1` auto-starts the stack at login when the active
  profile sets `DEV_DOCKER_STACK=true`. **No live profile does** since
  2026-10-03: `qwen3.6` + its CPU companion hold ~19 GB of the 32 GB (Ollama
  maps the whole 20.3 GB model file, GPU part included), and with the stack up
  available memory fell under 1.1 GB and the model paged mid-turn. Start it by
  hand when a project needs it.
- Devcontainers: shared base `dev/docker/dev.dockerfile` (node:22-bookworm +
  python3 (3.11) + build tools → tagged `dev-base:1` by
  `.\desktop\scripts\docker-base.ps1`). Project `.devcontainer/` live in the
  project repos (`M:\Projects\LFCbot`, `M:\TTRPG\A Story of Heroes and Villains`
  — the latter bakes Playwright chromium + deps). Use the `/devcontain` and
  `/sandbox` OpenCode commands, or `.\desktop\scripts\docker-sandbox.ps1`
  directly. Rule: `--rm` + `--memory` + `--cpus` on every throwaway; never
  mount secrets into containers.

Restart the consuming app after each: OpenCode (config/agents/commands), WezTerm (Lua).
