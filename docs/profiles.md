# Profiles

Profiles are bash files in `profiles/` that select which tiers are online, what
should be installed where, and what OpenCode uses by default. Source one per
shell:

```bash
source profiles/dev-workflow-quality.sh
```

Or pick from a menu:

```bash
bash profiles/select-model.sh
```

`select-model.sh` discovers profiles dynamically from `profiles/*.sh`, so the
menu always matches what is actually live. On Windows, dot-source
`profiles/dev-desktop-only.ps1` to load a profile into the current PowerShell
process (Git bash: `source profiles/<name>.sh`).

## Live vs parked (changed 2026-09-17)

**Three profiles are live.** All are desktop-only, because the server
(`SERVER_IP`) will not POST:

| Profile | Main seat | Use it when |
|---|---|---|
| `dev-workflow-quality` | `qwen3:14b` @32k + `qwen2.5-coder:3b` | default — everyday work |
| `dev-workflow-resident` | `qwen3:8b` @32k + `qwen2.5-coder-16k` | you want the 7B resident for code text |
| `dev-desktop-only` | `qwen3:8b` | plain local console, no extras |

**Nine are parked** in `profiles/parked/` — see
[`profiles/parked/README.md`](../profiles/parked/README.md). They are correct,
not deprecated; they target the server or the unprovisioned third node. Bringing
one back is a `git mv`.

Why park rather than leave them: the harness ran all twelve and emitted **38
WARNs**, every one of them "server unreachable." It now reports **81 PASS, 0
FAIL, 0 WARN**. Warnings you learn to scroll past are how the original config
bug survived for weeks.

> **Everything below this line describing server or cloud profiles refers to
> parked files.** The content is accurate and worth keeping for when the
> hardware returns — it just is not runnable today.

Every profile:

1. Loads `.env` from the repo root (`set -a && source ... && set +a`).
2. Exports `DEV_TIERS_{SERVER,DESKTOP,GO,NODE3}` toggles (consumed by `server/scripts/startup.sh` and `desktop/scripts/startup.ps1`).
3. Exports install intent: `DEV_SERVER_MODELS`, `DEV_DESKTOP_MODELS`, `DEV_NODE3_MODELS` (space-separated catalog tags or groups — consumed by `install-model.sh` / `models.ps1` with `--profile`/`-Profile`).
4. Sets OpenCode defaults: `OPENCODE_MODEL` / `OPENCODE_SMALL_MODEL` (model ID format `ollama-server/qwen2.5-coder:7b`) and the per-host `OLLAMA_*_BASE_URL`.

## The 9 parked profiles (in `profiles/parked/`)

Every main seat below is `qwen3:8b` — they were repointed on 2026-09-17 when the
tool-calling probe showed the coder and reasoner models cannot edit files. The
"Installs" column still lists those models because they remain useful as
no-tools models for code text and review.

| Profile | Purpose | Needs | Installs | Main seat |
|---------|---------|-------|----------|-----------|
| `dev-quick` | Fastest local loop, autocomplete only | Server | Server: `autocomplete` | `ollama-server/qwen3:8b` |
| `dev-coder` | Heavy coding offloaded to the server's 14B | Server | Server: `coder` | `ollama-server/qwen3:8b` |
| `dev-server-all` | Everything on the server, desktop idle | Server | Server: `autocomplete coder reasoner` | `ollama-server/qwen3:8b` |
| `dev-local-only` | Zero cloud spend; desktop main seat, server small model | Server + Desktop | Server: `autocomplete` · Desktop: `reasoner` | `ollama-desktop/qwen3:8b` |
| `dev-embeddings` | Semantic-search work; server hosts embed models | Server | Server: `autocomplete embed` | `ollama-server/qwen3:8b` |
| `dev-go-only` | Test cloud models you can't run locally via OpenCode Go | Server + Go | Server: `autocomplete` | *Go default* (cloud) |
| `dev-node3` | Onboard the node3's 3080 FE node (stub until `NODE3_IP` set) | Server (+ Node3) | Server: `autocomplete` · Node3: `general embed` | `ollama-node3/qwen3:8b`, falls back to server |
| `dev-full` | Everything online (server + desktop + Go) | Server + Desktop + Go | Server: `coder reasoner general creative embed` · Desktop: `reasoner` | *Go default* (cloud) |
| `dev-workflow-server` | Server drives, desktop assists | Server + Desktop | — | `ollama-server/qwen3:8b` |

The server copies of `qwen3:8b` have **never been probed** — the server has been
down since before `tests/test-toolcalls.ps1` existed. Probe before trusting one:

```powershell
.\tests\test-toolcalls.ps1 -Model qwen3:8b -OllamaHost http://SERVER_IP:11434
```

## The workflow profiles (`dev-workflow-*`, the default test target)

The three live profiles are what
`tests/test-profiles.ps1` validates by default (81 PASS, 0 FAIL, 0 WARN), each
against its intent manifest (purpose, tier flags, main/small model, and whether the main seat can actually call tools):

| Profile | Purpose | Main / small model |
|---------|---------|--------------------|
| `dev-workflow-quality` | Default. qwen3:14b drives in-thread at 32k, `/plan` on demand | `qwen3:14b` / `qwen2.5-coder:3b` |
| `dev-workflow-resident` | Same, but keeps the 7B coder resident as a no-tools code/review model | `qwen3:8b` / `qwen2.5-coder:7b` |
| `dev-desktop-only` | Plain local console, no dev stack, no extras | `qwen3:8b` / `qwen2.5-coder:7b` |

`dev-workflow-quality` also exports `DEV_DOCKER_STACK=true`, so `startup.ps1`
starts the local Postgres + Redis stack (`desktop/docker`) at login alongside
Ollama. The other two do not.

> **Changed 2026-09-17 (twice, final state):** `dev-workflow-quality`'s main
> seat moved `qwen2.5-coder:14b` → `qwen3:8b` → **`qwen3:14b`**. The coder
> cannot call tools — only the qwen3 family (8b/14b) and `devstral:24b` pass
> `tests/test-toolcalls.ps1`, verified on this exact stack. A coder or reasoner
> in an agent seat reports edits it never made; the 14B coder stays registered
> as a deliberate no-tools model. `/implement` and its coder subagent were
> removed for the same reason.
>
> `qwen3:14b` was briefly seated, then reverted the same morning: it issued
> **6 write calls for one request** where the 8B issued 1, and took 217 s
> against 96 s. It was re-seated in the afternoon for its loose-prompt intent
> handling (the whole point of the north star) — 11.03 GB @ 32k, 100% on GPU,
> 48.9 tok/s. **The repeated-tool-call risk is the known cost of this seat.**
> If a session shows repeated `← Write` lines, drop back to `qwen3:8b`. See
> `docs/troubleshooting.md` → "Passing the probe is necessary, not sufficient".

The third workflow profile, `dev-workflow-server`, is parked. It puts the heavy
models on the server and defaults `OLLAMA_SERVER_BASE_URL` to the server's LAN
IP (`SERVER_IP` from `.env`) — not `localhost`, which is what the older `dev-*`
server profiles use.

### Plan toggle is NOT `/plan`

The bottom-left Plan/Build toggle in the OpenCode UI only controls *tool
permissions* for whatever model is driving the session. It does **not** switch
model and it does **not** write `docs/implementation-tasks.md` (in Plan mode the
model cannot use write/edit tools). To get the task list you must type the real
command:

```
/plan <scope>
```

That runs on the **main agent** and writes `docs/implementation-tasks.md`. It
used to dispatch a `planner` subagent; that agent was deleted on 2026-09-17
because it never called the write tool — it returned the plan as chat text and
the parent then reported a file that did not exist. Typing a raw request in Plan
mode just asks the session's current model for a text plan; no file is written.

**Check `/plan` output before acting on it.** In a verified run its line numbers
were accurate and two of its three interpretations were inverted. Details:
`docs/troubleshooting.md` → "`/plan` works now — but verify every claim".

Coding work is driven by the **main session model**, which must be `qwen3:14b`
(or `qwen3:8b` in the lighter profiles).

### Every main seat is a tool-capable model — keep it that way

Every live and parked profile seats a qwen3 (8b or 14b) — the only family that
passes the probe. Before 2026-09-17 most seated a `qwen2.5-coder` or
`deepseek-r1` tag, **none of which can call tools** —
those sessions answered questions and described changes but never touched the
filesystem, and reported success anyway. See `docs/troubleshooting.md` → "Agent
'says' it edited a file".

Two things now prevent a regression: models that fail the probe carry
`"tool_call": false` in the OpenCode config, and `tests/test-profiles.ps1` FAILs
any profile whose main seat is not tool-capable.

If a session seems to be doing nothing, check which model is driving. A bare
`opencode` launch falls back to User-level env defaults rather than a profile —
launch via `desktop\scripts\opencode.ps1`, which sources one for you.

## VRAM budgets are measured, not catalog sizes

`catalog.tsv` `size_gb` is the GGUF on disk. Runtime VRAM adds the KV cache and
compute buffers and runs 1–3 GB higher, and only ~14.8 GB of the desktop's
16 GB is usable. Budgeting from disk size is what put the 14B and the 7B in the
same profile when they do not fit — loading the small model evicted the main
one, costing a 14.1 s reload plus a lost prompt cache on the very next turn.

Measured with `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0`:

| Profile | Resident pair | VRAM |
|---|---|---|
| `dev-workflow-quality` | `qwen3:14b` @32k + `qwen2.5-coder:3b` @16k | 11.03 + 2.26 = **13.29 GB** |
| `dev-workflow-resident` | `qwen3:8b` @32k + `qwen2.5-coder-16k` @16k | 7.16 + 4.81 = **11.97 GB** |

`/plan` runs on the main agent, so no separate planner model swaps in.
`qwen2.5-coder:14b` (11.27 GB) can be swapped in deliberately for a no-tools
review pass and does not co-reside. Verify any change with `curl :11434/api/ps`
— expect *both* models listed. Details and the flash-attention trade-off:
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