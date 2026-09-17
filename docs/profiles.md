# Profiles

Profiles are bash files in `profiles/` that select which tiers are online, what should be installed where, and what OpenCode uses by default. Source one per shell:

```bash
source profiles/dev-quick.sh
```

Or pick from a menu:

```bash
bash profiles/select-model.sh
```

> `select-model.sh` menus the nine fallback profiles; it does not list the
> `dev-workflow-*` trio. On Windows, dot-source `profiles/dev-desktop-only.ps1`
> to load a profile into the current PowerShell process (Git bash:
> `source profiles/<name>.sh`).

Every profile:

1. Loads `.env` from the repo root (`set -a && source ... && set +a`).
2. Exports `DEV_TIERS_{SERVER,DESKTOP,GO,NODE3}` toggles (consumed by `server/scripts/startup.sh` and `desktop/scripts/startup.ps1`).
3. Exports install intent: `DEV_SERVER_MODELS`, `DEV_DESKTOP_MODELS`, `DEV_NODE3_MODELS` (space-separated catalog tags or groups — consumed by `install-model.sh` / `models.ps1` with `--profile`/`-Profile`).
4. Sets OpenCode defaults: `OPENCODE_MODEL` / `OPENCODE_SMALL_MODEL` (model ID format `ollama-server/qwen2.5-coder:7b`) and the per-host `OLLAMA_*_BASE_URL`.

## The 9 profiles

| # | Profile | Purpose | Online | Installs | Default OpenCode model |
|---|---------|---------|--------|----------|------------------------|
| 1 | `dev-quick` | Fastest local loop, autocomplete only | Server | Server: `autocomplete` | Qwen 2.5 Coder 7B (server) |
| 2 | `dev-coder` | Heavy coding offloaded to the server's 14B | Server | Server: `coder` | Qwen 2.5 Coder 14B (server) |
| 3 | `dev-server-all` | Everything on the server (coder + reasoner + autocomplete), desktop idle | Server | Server: `autocomplete coder reasoner` | Qwen 2.5 Coder 14B (server) |
| 4 | `dev-desktop-only` | **All local on this PC** — for when the server is out of commission; no cloud | Desktop | Desktop: `qwen2.5-coder:7b deepseek-r1:14b qwen3:8b` | DeepSeek-R1 16k (desktop) |
| 5 | `dev-local-only` | Zero cloud spend; Qwen on server, DeepSeek reasoner on desktop | Server + Desktop | Server: `autocomplete` · Desktop: `reasoner` | DeepSeek-R1 16k (desktop) |
| 6 | `dev-embeddings` | Semantic-search work (MTG/TTRPG apps); server hosts embed models | Server | Server: `autocomplete embed` | Qwen 2.5 Coder 7B (server) |
| 7 | `dev-go-only` | Test cloud models you can't run locally via OpenCode Go | Server + Go | Server: `autocomplete` | *Go default* (cloud) |
| 8 | `dev-node3` | Onboard the node3's 3080 FE node (stub until `NODE3_IP` set) | Server (+ Node3) | Server: `autocomplete` · Node3: `general embed` | Qwen3 8B (node3) / falls back to server 7B |
| 9 | `dev-full` | Everything online (server + desktop + Go) | Server + Desktop + Go | Server: `coder reasoner general creative embed` · Desktop: `reasoner` | *Go default* (cloud) |

## The workflow profiles (`dev-workflow-*`, the default test target)

All dozen profiles on disk (everything except `select-model.sh`) are what
`tests/test-profiles.ps1` validates by default, each against its intent
manifest (purpose, tier flags, main/small model, main-seat role):

| Profile | Purpose | Online | Default OpenCode model |
|---------|---------|--------|------------------------|
| `dev-workflow-quality` | qwen3:8b drives in-thread at 32k, `/plan` on demand | Desktop | `qwen3:8b` (main) / `qwen2.5-coder:3b` (small) |

> **Changed 2026-09-17:** the main seat was `qwen2.5-coder:14b`. It cannot call
> tools — only 1 of 8 installed models can (`qwen3:8b`), verified by
> `tests/test-toolcalls.ps1`. A coder or reasoner in an agent seat reports
> edits it never made. The 14B stays registered as a deliberate no-tools model.
> `/implement` and its coder subagent were removed for the same reason.

The `quality` profile also exports `DEV_DOCKER_STACK=true`, so `startup.ps1`
starts the local Postgres + Redis stack (desktop/docker) at login alongside
Ollama.
| `dev-workflow-resident` | Qwen3 8B drives; 7B coder kept resident as a no-tools code/review model | Desktop | `qwen3:8b` (main) / `qwen2.5-coder:7b` (small) |
| `dev-workflow-server` | Server's 14B coder + autocomplete, desktop R1 planner (for when the server is back) | Server + Desktop | `ollama-server/qwen2.5-coder:14b` (main) / `ollama-server/qwen2.5-coder:7b` (small) |

All three are desktop-first: the OpenCode UI runs on the Windows box and the
heavy coder lives either locally (`quality`, `resident`) or on the server
(`server`). `dev-workflow-server.sh` defaults `OLLAMA_SERVER_BASE_URL` to the
server's LAN IP (`SERVER_IP` from `.env`) — not `localhost`, which is what the
older `dev-*` server profiles use.

### Plan toggle is NOT `/plan`

The bottom-left Plan/Build toggle in the OpenCode UI only controls *tool
permissions* for whatever model is driving the session. It does **not** switch
model and it does **not** write `docs/implementation-tasks.md` (in Plan mode the
model cannot use write/edit tools). To get the task list you must type the real
command:

```
/plan <scope>
```

That dispatches a separate **planner subagent** pinned to
`ollama-desktop/qwen3:8b` whose contract is to read the repo and write the
two-section task doc. Typing a raw request in Plan mode just asks the session's
*current* model for a text plan — no file is ever written.

Coding work itself is driven by the **main session model**, which must be
`qwen3:8b` — the only installed model that can call tools.

### Any profile that puts a coder or reasoner in the main seat is chat-only

`dev-desktop-only` and `dev-local-only` set `OPENCODE_MODEL` to
`deepseek-r1-16k`; `dev-workflow-server` and the older `dev-*` profiles point at
`qwen2.5-coder`. **None of those models can call tools** — see
`docs/troubleshooting.md` → "Agent 'says' it edited a file". Sessions launched
under them will answer questions and describe changes but never touch the
filesystem, and will often report success anyway.

If you see a session defaulting to `model.id=deepseek-r1-16k` or a
`qwen2.5-coder` tag and "nothing happening", you are under one of those profiles
(or a launch that didn't source a profile and fell back to a stale picker
default). Re-source `dev-workflow-quality.sh`, or launch via
`desktop\scripts\opencode.ps1`, which sources it for you. Those profiles are
kept for deliberate no-tools use (ask-a-question sessions), not for agent work.

## VRAM budgets are measured, not catalog sizes

`catalog.tsv` `size_gb` is the GGUF on disk. Runtime VRAM adds the KV cache and
compute buffers and runs 1–3 GB higher, and only ~14.8 GB of the desktop's
16 GB is usable. Budgeting from disk size is what put the 14B and the 7B in the
same profile when they do not fit — loading the small model evicted the main
one, costing a 14.1 s reload plus a lost prompt cache on the very next turn.

Measured with `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0`:

| Profile | Resident pair | VRAM |
|---|---|---|
| `dev-workflow-quality` | `qwen3:8b` @32k + `qwen2.5-coder:3b` @16k | 7.16 + 1.31 = **8.47 GB** |
| `dev-workflow-resident` | `qwen3:8b` @32k + `qwen2.5-coder-16k` @16k | 7.16 + 4.81 = **11.97 GB** |

The planner runs `qwen3:8b` too, so `/plan` no longer swaps a 12 GB reasoner in. `qwen2.5-coder:14b` (11.27 GB) can be swapped in deliberately for a no-tools review pass and does not
co-reside. Verify any change with `curl :11434/api/ps` — expect *both* models
listed. Details and the flash-attention trade-off:
[`docs/hardware.md`](hardware.md).

## Tools are scoped per project, not per profile

Profiles choose *models*. They do not choose MCP servers or skills — those are
scoped by config layer, because every MCP tool schema and every skill
description is injected into the system prompt of **every** request. With all
of them enabled the preamble measured 46,505 tokens against a 16k model, which
Ollama truncated down to 8,194 and the request died.

- **Global** (`opencode/global/opencode.jsonc`): zero MCP servers, and only the
  `frontend-design` + `ui-ux-pro-max` skills. `sync-skills.ps1` deploys exactly
  that set (`-Scope all` overrides; `-Prune` removes out-of-scope leftovers).
- **Project** (`opencode.jsonc` in the project root): opts into what it needs.
  opencode deep-merges project over global, and `{ "enabled": false }` switches
  off an inherited server. Skills are referenced in place —
  `"skills": { "paths": ["M:/Projects/dev-docs/skills/vercel"] }` — so nothing
  is copied and the project always sees current repo content.

Template with every option commented:
`opencode/project-override/opencode.jsonc`. Set a project up once and every
session in that directory, including inside its devcontainer, gets the right
tools with no per-session toggling.

## Selection rules of thumb

- **Low interference, fastest loop** → `dev-quick`, `dev-coder`.
- **Server down / out of commission** → `dev-desktop-only` — signs off the server tier and runs the whole loop (autocomplete + reasoner + general) locally on the PC with an OpenCode default that never points at the dead box.
- **Reasoning on one box** → `dev-server-all` keeps the desktop idle and free for gaming/day-to-day.
- **Resource search / embeddings** → `dev-embeddings`.
- **Budget-first** → `dev-local-only` (no cloud spend at all).
- **Evaluating a cloud model before pulling it** → `dev-go-only`.
- **Everything up** → `dev-full`.

## Environment variables

| Variable | Meaning | Set by |
|----------|---------|--------|
| `DEV_TIERS_SERVER` | Start server Ollama at boot | all profiles (true/false) |
| `DEV_TIERS_DESKTOP` | Start desktop Ollama at boot | desktop-only, local-only, full |
| `DEV_TIERS_GO` | OpenCode Go subscription available | go-only, full |
| `DEV_TIERS_NODE3` | Third node online (requires `NODE3_IP`) | dev-node3 |
| `DEV_SERVER_MODELS` | Catalog tags/groups for the server | all |
| `DEV_DESKTOP_MODELS` | Catalog tags/groups for the desktop | desktop-only, local-only, full |
| `DEV_NODE3_MODELS` | Catalog tags/groups for the third node | dev-node3 |
| `OPENCODE_MODEL` | OpenCode default main model | most profiles |
| `OPENCODE_SMALL_MODEL` | OpenCode default small/autocomplete model | most profiles |
| `OLLAMA_SERVER_BASE_URL` | OpenCode `ollama-server` provider endpoint | default `http://localhost:11434/v1` |
| `OLLAMA_DESKTOP_BASE_URL` | OpenCode `ollama-desktop` provider endpoint | desktop-only (`localhost`), local-only, full |
| `OLLAMA_NODE3_BASE_URL` | OpenCode `ollama-node3` provider endpoint | dev-node3 |

## `dev-node3` interplay with `.env`

`dev-node3.sh` is a stub: it activates the third-node tier **only** when `NODE3_IP` is set in `.env`. Otherwise it warns and behaves like `dev-quick` with a server-side default. Deactivate it by sourcing another profile.

## Reasoner placement (how it was split)

There is no single "reasoner" profile — that was deliberate. Instead:

- **`dev-server-all`** runs DeepSeek-R1 14B on the server (fast, desktop stays idle).
- **`dev-local-only`** runs DeepSeek-R1 14B on the desktop (native Vulkan, 16k ctx bake) for zero-spend sessions.
- **`dev-desktop-only`** also runs it on the desktop — with everything else local — when the server is out of commission.
- **`dev-full`** has both hosts able to run it.

Need a reasoner on a specific box → use the matching profile; that's the whole point of keeping placement flexible.