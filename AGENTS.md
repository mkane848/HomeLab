# AGENTS.md

Repo for provisioning a hybrid Ubuntu server / Windows desktop LLM setup (Ollama + OpenCode). Not an app codebase — most changes are bash/PowerShell scripts, JSONC config templates, and docs.

**End goal (north star): turn every machine in the house into interchangeable compute for one Claude Code / ChatGPT Codex-like development experience** — prompt in plain human language, and the fleet (personal PC today, the Ubuntu server when it's fixed, then node3's 3080 FE) flexibly supplies the models behind that experience. The mechanics documented in this repo exist so you don't have to think about which model runs where: the profile selects it, OpenCode pins it, tests enforce it. See `docs/roadmap.md`. Progress gates by hardware, not by preference.

**This repo is under git as of 2026-09-17.** It was not before, and that cost real work: an agent asked to edit `desktop/scripts/sync-skills.ps1` left three duplicated blocks and three unbalanced braces in it, and the only recovery was reading the damage by hand. There was no `git diff` and no `git checkout --`.

- **Commit before letting an agent edit anything.** `git status` should be clean when you start.
- After an agent edits a script, `git diff` it and syntax-check before running it. PowerShell
  (wrapped so only errors print, not the whole AST — the bare `ParseFile(...)` call dumps a
  `ScriptBlockAst` to the pipeline):
  `$errs = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile(<path>,[ref]$null,[ref]$errs); if ($errs.Count) { $errs } else { "OK" }`.
  Verified legal on both PS 7 and Windows PowerShell 5.1 (`[ref]$null` as a discard out-param
  works on both). Shell: `bash -n`.
- `.env`, `desktop/docker/.env` and anything `*.env` are git-ignored; only `.env.example` templates are tracked. Secrets live in `~/.config/opencode/.secrets/`, outside the repo entirely.
- Remote is `origin` (`github.com/mkane848/HomeLab`). Don't force-push `main`; revert-and-re-PR instead.

Machines: `server` (SERVER_IP, RTX 4070 Ti Super 16GB, Docker — down, won't POST), `desktop` (this PC, RX 6800 XT 16GB Vulkan, native), `node3` (RTX 3080 FE 10GB, onboarded 2026-09-20 — `qwen3:8b` is the only agent seat; `glm4:9b` is no-tools, probed). Hosts often down — all sync scripts must degrade gracefully (see Gotchas).

## Active workflow ("qwen3 is the boss")

The `/plan` → execute flow is the reason the workflow agents/commands exist and it pins models via OpenCode, not vram juggling:

**The main seat runs `qwen3:14b`** — it passes the tool-call probe along with `qwen3:8b`, `qwen3.5:9b`, `qwen3-coder:30b-a3b` and `devstral:24b` (5 of 13 installed models, measured on Ollama 0.34.1; see Gotchas and `tests/test-toolcalls.ps1`). A coder or reasoner in an agent seat will *claim* it edited files it never touched.

- `/plan <scope>` (`opencode/commands/plan.md`, runs on the main agent) uses **the main session model**: reads the repo, writes/updates `docs/implementation-tasks.md` (risks/gaps cited by `file:line`, ordered file-scoped tasks with definitions of done). It was pinned to DeepSeek-R1, which cannot call the write tool and hallucinated success instead ("The task tool has written…").
- Then tell the main session model — **`qwen3:14b`** — to "execute task #N from docs/implementation-tasks.md". Coding never goes through delegation.
- **There is no coder subagent and no `/implement`.** Both were removed 2026-09-17: the subagent was pinned to `qwen2.5-coder-16k` (the 7B), which cannot call tools, so `/implement` silently did nothing. A command that looks like it works and doesn't is worse than no command. AGENTS.md already said coding belongs in-thread — now the config agrees.
- `qwen2.5-coder:14b` stays registered as a **no-tools** model: fine to switch to deliberately for code text, explanation or review, useless as an agent.

**The Plan/Build toggle is not `/plan`.** The bottom-left toggle only gates tool
permissions for the *current* session model; it does not switch model and it
does not write the task doc (Plan mode has no write/edit tools). `/plan <scope>`
is the only way to get the task doc written. The main session model must be
`qwen3:14b` (or `qwen3:8b` when you need the lighter/latency-tuned seat) —
anything else cannot call tools. Launch OpenCode via
`desktop\scripts\opencode.ps1` (sources the active workflow profile + sets
process env) or from a shell that has sourced the profile; a bare launch falls
back to User-level defaults.

Live profiles are `dev-workflow-quality.sh` (default), `dev-workflow-resident.sh`, `dev-desktop-only.sh` and `dev-node3.sh`; they set `OPENCODE_MODEL`/`OPENCODE_SMALL_MODEL`/`DEV_*_MODELS`. Eight server profiles are parked in `profiles/parked/` — see its README for the bring-back procedure (`git mv` + `test-profiles.ps1 -Profile <name>`; probe server models before seating — the server has never run `test-toolcalls.ps1`).

## Model catalog (single source of truth)

- `models/catalog.tsv` — every model we can run, tab-separated so both bash and PowerShell parse it. Columns: `tag  size_gb  class  ctx  groups  hosts  desc`.
  - `class`: `fit` (16GB VRAM), `edge` (tight), `offload` (needs system RAM).
  - `groups`: install groups `autocomplete coder reasoner general creative embed`.
  - `hosts`: eligible machines `server desktop node3` (`all` = any).
- `models/catalog.sh` — bash library. **Sourced, never executed.** Use `source models/catalog.sh` then `catalog_list`, `catalog_list <group>`, `catalog_field <tag> <col>`, `catalog_has_tag`, `catalog_groups`.
- To add a model: add a row to `catalog.tsv`; register it in the matching provider block of `opencode/global/opencode.jsonc` so it appears in OpenCode's `/models` after install; then stage + sync (below). **Probe it first** — `.\tests\test-toolcalls.ps1 -Model <tag>` — and only seat it as a main model or tool-using subagent if it PASSes.
- **Not every catalog row belongs in `opencode.jsonc`, and not every `opencode.jsonc` entry is in the catalog — both by design.** `nomic-embed-text` and `mxbai-embed-large` are embedding models: they have no chat endpoint, and registering them would offer them in `/models` as if you could talk to them. They live in the catalog (so `models.ps1 -Group embed` installs them) and are consumed directly via `/api/embeddings`. A tag registered on one host's provider but not another's is usually deliberate too (`gemma3:12b` is server-block only and unprobed; `qwen3:14b` is deliberately absent from the node3 block — tight on 10 GB). Conversely the three LM-Studio imports on desktop (`qwen3-coder:30b-a3b`, `qwen3.5:9b`, `deepseek-r1-0528:8b`) are registered but have no catalog row. A catalog↔config diff is not automatically a defect; check which of these three cases it is first.
- Serve context: server honors `OLLAMA_CONTEXT_LENGTH` (16384 default). Desktop bakes it (see Gotchas) — the catalog `ctx` and OpenCode model IDs assume the served number, so the client never over-promises.

## Installing models

- Server (Docker): `./server/scripts/install-model.sh <tag|group|all|--profile>`. `--profile` reads `DEV_SERVER_MODELS`. `--ctx N` creates a derived `<tag>-Nk` model with baked `num_ctx`. Runs `docker exec ollama-server ollama ...`.
- Desktop (native, Vulkan): `.\desktop\scripts\models.ps1 -Pull <tags> | -Group <g> | -All | -Profile` (`-Profile` reads `DEV_DESKTOP_MODELS`), `-Context N` bakes a derived model, `-List` lists installed. `startup.ps1` auto-pulls missing bake targets and bakes a per-model `num_ctx` (32768 for `qwen3:14b`, `qwen3:8b` and `qwen2.5-coder:14b`; `deepseek-r1:14b` stays 16384 with baked `deepseek-r1-16k`/`-32k` aliases; 16384 for the rest — see `$contextModels`).

## Profiles (`profiles/dev-*.sh`)

Each profile is sourced bash that (1) loads `.env` from repo root via `set -a && source "$DEVDOCS_ENV" && set +a`, then (2) exports tier toggles + model intent + OpenCode defaults:

- `DEV_TIERS_SERVER/DESKTOP/GO/NODE3` — true/false, read by `server/scripts/startup.sh` and `desktop/scripts/startup.ps1`.
- `DEV_SERVER_MODELS` / `DEV_DESKTOP_MODELS` — space-separated catalog tags/groups to install on each host.
- `OPENCODE_MODEL` / `OPENCODE_SMALL_MODEL` — consumed by OpenCode config via `{env:...}`.
- `OLLAMA_DESKTOP_URL`/`OLLAMA_DESKTOP_BASE_URL`, `OLLAMA_SERVER_BASE_URL`, `OLLAMA_NODE3_BASE_URL` — one host per OpenCode provider.

On Windows, load the profile into the current process: PowerShell `. \profiles\dev-desktop-only.ps1` (dot-source; sets process-scope env), or Git bash `source profiles/dev-desktop-only.sh`. There is no `lib/load-env.ps1` — `dev-desktop-only.ps1` is the only PowerShell wrapper. `select-model.sh` is an interactive fzf picker that discovers `profiles/*.sh` dynamically, so it always lists exactly the live profiles (currently four) and nothing parked.

## OpenCode config

- Template lives at `opencode/global/opencode.jsonc`; the live config is `~/.config/opencode/opencode.jsonc` on each machine. Edit the template, then redeploy via `sync-opencode.ps1 -Template` (below).
- Providers are split one-per-host: `ollama-server`, `ollama-desktop`, `ollama-node3` (a single ollama provider can't reach two hosts). Model ID format: `ollama-server/qwen2.5-coder:7b`.
- The global `mcp` block is **empty on purpose**. Every MCP server's full tool schema rides in every request's system prompt; the five that used to live here (`vercel`, `render`, `docker`, `browser`, `postgres` — ~105 tools) were most of a 46,505-token preamble that a 16k local model cannot hold. Servers now go in the **project's** `opencode.jsonc`, which deep-merges over global (`{ "enabled": false }` switches off an inherited one). Template with all five commented and ready: `opencode/project-override/opencode.jsonc`.
- Skills are scoped the same way: global ships only `frontend-design` + `ui-ux-pro-max`; a project pulls in more by path (`"skills": { "paths": ["M:/Projects/dev-docs/skills/vercel"] }`) — referenced in place, never copied.
- API keys go in `~/.config/opencode/.secrets/*` (plaintext files referenced via `{file:...}` substitution) — never in `.env` or the config. `.env` only holds IPs/SSH user and is git-ignored. **`{file:...}` refs are resolved at config load** — a referenced path that doesn't exist → config is invalid and OpenCode won't start. Create placeholder files first.
- Agents and commands are templates in `opencode/agents/*.md` and `opencode/commands/*.md`; they are staged to the live config by `sync-opencode.ps1 -Template`. **Agents/commands/config are read at session start — restart any running OpenCode after syncing.**

## Sync pipeline (desktop → the world)

| Script | What it does |
|---|---|
| `.\desktop\scripts\sync-opencode.ps1 -Template` | Stage `opencode/global/*.jsonc` + `agents/` + `commands/` → `~/.config/opencode/`, then push config + agents + commands + `.secrets` to the server via scp. Without `-Template` pushes the live local config as-is. Down host → local staging done, press skipped, warning, exit 0. |
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
  profile sets `DEV_DOCKER_STACK=true` (dev-workflow-quality does).
- Devcontainers: shared base `dev/docker/dev.dockerfile` (node:22-bookworm +
  python3 (3.11) + build tools → tagged `dev-base:1` by
  `.\desktop\scripts\docker-base.ps1`). Project `.devcontainer/` live in the
  project repos (`M:\Projects\LFCbot`, `M:\TTRPG\A Story of Heroes and Villains`
  — the latter bakes Playwright chromium + deps). Use the `/devcontain` and
  `/sandbox` OpenCode commands, or `.\desktop\scripts\docker-sandbox.ps1`
  directly. Rule: `--rm` + `--memory` + `--cpus` on every throwaway; never
  mount secrets into containers.

Restart the consuming app after each: OpenCode (config/agents/commands), WezTerm (Lua).

## Verification

- **`.\tests\test-profiles.ps1`** is the primary harness. Runs **every live profile by default** (`profiles/*.sh` except `select-model.sh` — currently 4; parked ones in `profiles/parked/` are excluded automatically. `-Profile <name>` runs one). Each profile is checked against an **intent manifest**: purpose string, expected `DEV_TIERS_*` flags, expected `OPENCODE_MODEL`/`OPENCODE_SMALL_MODEL` (GoDefault profiles must leave them unset), and whether the main seat is **tool-capable** (`tool_call` in the resolved config — a profile seating a model that cannot call tools is a FAIL; the old role-based check was removed 2026-09-17 as both obsolete and wrong). Then the existing contract checks: referenced models registered in the live config, host liveness, derived-model presence. `-RoundTrip` additionally makes every referenced model answer a prompt AND runs a **capability probe** (coder → python function, reasoner → arithmetic w/ reasoning, general → Q&A; embed models → `/api/embeddings`) plus a **latency benchmark** against per-model ms budgets. `-Bench` implies `-RoundTrip` and turns over-budget into FAIL (instead of WARN) and prints a summary table. Applies intent + benchmarks per-profile, and gates the `localhost` server-baseURL WARN to `dev-workflow-server` only. Emits PASS/FAIL/WARN/SKIP; WARN = state to fix (e.g. blank `OLLAMA_SERVER_BASE_URL`, unprovisioned host, missing installs), FAIL = broken; exit 1 on any FAIL. A `-RoundTrip` model returning `EMPTY content` is the reasoning-model max_tokens trap — see Gotchas.
- Bash syntax: `"C:\Program Files\Git\bin\bash.exe" -n <script>`; behavior: `bash -c 'source models/catalog.sh && catalog_list'`.
- PowerShell: `.\desktop\scripts\models.ps1 -List`.
- Server runtime checks: `./server/scripts/status.sh` (also runs `nvidia-smi`), `curl :11434/api/ps`.
- OpenCode: `opencode debug config` (does it load + resolve `{env:}`), `opencode debug providers` (provider status).
- `-Reliability` (on `test-profiles.ps1`) is the write-discipline canary: single-write prompt through `opencode run` on every tool-capable main seat, FAILs on >1 write call (the regression that once unseated `qwen3:14b`) or on zero (liar mode). Slow — runs a real task per seat.
- `.\tests\test-tasks.ps1` is the task-veracity benchmark: fixed prompts through the real `opencode run` tool loop in throwaway worktrees (`tests/.worktrees/`, git-ignored), graded mechanically on scope / suite / failsOnOld / typecheck. `failsOnOld` is the load-bearing gate — revert source, keep the model's test, suite must FAIL. See its header + `tests/tasks/`.
- `.\tests\run-tasks-batch.ps1` wraps it for day-to-day use: ensures every task's local `bench/*` branch exists (idempotent — see "Task-veracity benchmark: task set expansion" in `docs/roadmap.md` for the branch↔commit table), then interactively prompts for which task(s), which model(s), and how many repeats of each, and runs `test-tasks.ps1` once per (task, model, rep). `-SetupOnly` just creates missing branches; `-SkipSetup` skips straight to the prompts. Sequential by design — true concurrency (different task IDs only, never the same one twice) still means two separate terminals running `test-tasks.ps1` directly, per the worktree-keyed-by-task-id constraint.
- Model-written PRs: a **green suite is necessary, not sufficient**. Audit every
  new test against the branch it claims to cover (a passing test can be green on
  broken code) and run integration on a seeded DB before merge. Method + the
  PR #82 Background-bug worked example in `docs/review-gate/testing.md`.
- PRs: title `type: description` (`docs: …`, `tests: …`, `fix: …`), fill the
  Verification section with commands run (not assertions), add a `[Unreleased]`
  `CHANGELOG.md` entry. Template: `.github/PULL_REQUEST_TEMPLATE.md`; rules: `CONTRIBUTING.md`.

## Gotchas

- **Files copied from Windows to the server lose the exec bit** — run `./make-executable.sh` after scp. (Syntax-check local .sh files from Windows first with Git bash.)
- **Only the qwen3 family can reliably call tools; `devstral:24b` passes too but is a solo-seat edge fit.** Measured on Ollama 0.34.0 against `/api/chat` with a tool schema, and **re-measured on 0.34.1 (2026-09-19) with every result reproduced, including each failure's mode** — `tests/results/toolcalls-0.34.1.txt`. Passing: `qwen3:8b`, `qwen3:14b`, `qwen3.5:9b`, `qwen3-coder:30b-a3b` (the review-gate auditor seat), and `devstral:24b` (which partially offloads). Failing: the whole `qwen2.5-coder` family (`3b`/`7b`/`14b`/`-16k`) returns **empty** `tool_calls` and prints the call as chat text; the whole `deepseek-r1` family (`14b`/`-16k`/`-32k`/`-0528:8b`) ignores the tool and answers in prose. The Qwen2.5 template needs `<tool_call></tool_call>` tags the coder weights never emit; not caused by the `num_ctx` bake (a pristine re-pull behaves the same). `ollama show` listing a `tools` capability only means the *template* supports tools. **Any seat that must read/edit/run belongs to the qwen3 family** — a coder or reasoner there is a chat box that will claim it edited files it never touched. `qwen3:14b` is the default main seat (dev-workflow-quality); it was previously unseated when it once issued 6 write calls for a single request — if you see repeated `← Write` lines in a session, drop back to `qwen3:8b`. See `docs/troubleshooting.md` → "Agent 'says' it edited a file" and "Passing the probe is necessary, not sufficient — watch for repeated calls". **`glm4:9b` was never part of that 13-model batch and is a separate measured result:** probed for real on node3 (2026-09-20, `tests/test-toolcalls.ps1 -Model glm4:9b -OllamaHost http://NODE3_IP:11434`) — **FAIL**, ignored the tool entirely and answered in prose ("To write the text 'hello' to a file..."), same failure shape as the `qwen2.5-coder`/`deepseek-r1` families above. `opencode/global/opencode.jsonc`'s `ollama-node3` block previously declared `"tool_call": true` for it with no measurement behind that claim — corrected to `false` now that one exists. `qwen3:8b` was probed on the same node3 host in the same session and **passed** (62.3s, real `write_file` tool call), confirming the qwen3 family's tool-calling holds across the CUDA backend too, not just Vulkan/desktop.
- **OpenCode silently drops unknown model keys.** `context_window` and a bare `input` are not in the schema; they vanish without an error and the model resolves with **no limits**, so OpenCode never trims the prompt and reserves ~8192 for output. Result: a 46,505-token prompt at a 16k model, `truncating input prompt limit=8194 prompt=46505 keep=4`, system prompt destroyed, 5-minute 500. Correct keys: `limit: { context, output }`, `modalities: { input, output }`, `tool_call`. **Always confirm with `opencode debug config` that the resolved entry still has `limit`** — the template proves nothing.
- **Preamble budget.** Every MCP server's tool schema and every installed skill's description ride in *every* request. That is why global config ships zero MCP servers and 2 skill sources (`$GLOBAL_SKILL_SOURCES` in `sync-skills.ps1`; was 5 servers + full skill set = 46.5k tokens, now ~11.4k). Projects opt in via their own `opencode.jsonc` — see `opencode/project-override/opencode.jsonc`. Measure with `opencode run ... "Reply with exactly: OK"` and read `task.n_tokens` from the Ollama log. **Beware the `~/.claude` rider:** OpenCode auto-loads every skill under `~/.claude/skills/<name>/SKILL.md` as a "Claude-compatible" skill and its description rides in every request — the Claude Code plugin's synced skills (`~/.claude/skills/synced/`, 10 files, 167 KB) added ~2.5k tokens of standing overhead unaccounted for by any `$GLOBAL_SKILL_SOURCES`. Measured 2026-09-20 on the desktop: OK probe 16,851 tokens (113 s prefill) with them, 14,364 tokens (84 s) with `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1`. That env var is set in every live profile and as a User-level default; keep it set — a bare `opencode` launch without it silently reloads the synced skills.
- **Context length**: baked per model by `startup.ps1` (`$contextModels`) — 32768 for `qwen3:14b`, `qwen3:8b` and `qwen2.5-coder:14b`; `deepseek-r1-14b` stays 16384 with baked `-16k`/`-32k` aliases; 16384 for the rest. `$contextModels` and `limit.context` in `opencode.jsonc` are two halves of one contract; changing one without the other brings the truncation back. `OLLAMA_CONTEXT_LENGTH` *is* honoured on Windows as of Ollama 0.34.0 (the old "the app zeroes it" note was a v0.32 bug, now fixed) — we bake anyway because the env var is a single global default and we need per-model control.
- **VRAM: use measured numbers, never catalog disk size.** `catalog.tsv` sizes omit KV cache and compute buffers and undercount by 1–3 GB. Only ~14.8 GB of the 16 GB is usable. `qwen2.5-coder:14b` @32k = 11.27 GB, so its companion must be the **3b** (2.26 GB), not the 7b (5.22 GB) — the 7b evicts it and costs a 14.1 s reload plus a lost prompt cache on the next turn. Check with `curl :11434/api/ps` and expect *both* models listed.
- **The desktop GPU runs Vulkan, not ROCm** — gfx1030 is unsupported by the Windows HIP SDK and `OLLAMA_VULKAN=0` drops the box to CPU-only. Settled; see `docs/troubleshooting.md`. Flash attention is required for quantized KV but *costs* prefill throughput on Vulkan (103 vs 191 tok/s); we keep `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` because fitting two models beats raw prefill.
- **PowerShell ⇄ bash output mangling**: piping Git-bash stdout into PowerShell renders as UTF-16/ANSI garbage. Redirect bash output to a file and read the file.
- **Never pass `gh pr create/edit --body "..."` inline from PowerShell.** Backtick is PowerShell's escape character (`` `n `` → newline), so every code span is eaten and stray backslashes litter the rendered PR (this happened on PR #19/#20 and had to be fixed with `gh pr edit`). Write the body to a file and use `--body-file`, then confirm with `gh pr view <n> --json body --jq .body`.
- **`$ErrorActionPreference = "Stop"` + native stderr**: a native command's stderr becomes a terminating error under Stop. Scripts that probe fallible hosts (e.g. ssh) must temporarily drop to `Continue` around the probe (see `sync-opencode.ps1`). `startup.ps1` must be run plain (`. \startup.ps1`), never with `*>` redirection — it re-executes itself.
- **Reasoning models + small `max_tokens`** return empty content (budget burned on the `reasoning` block, `finish_reason: "length"`). Keep `max_tokens` ≥256 for DeepSeek-R1/Qwen3; don't blame the profile.
- **`{env:...}` has no fallbacks.** OpenCode's substitution does not support `:-default`; `"{env:VAR:-http://…}"` resolves to an empty string and providers fail with `"/chat/completions" cannot be parsed as a URL`. Values must come from the active profile (or User-level env defaults on the desktop so OpenCode works without sourcing).
- **Docker on the desktop** won't start its engine unless `C:\Users\<username>\.wslconfig` has `[wsl2] gpuSupport=false` (workaround for a WSL ConfigureGpu signature error). The desktop runs Docker Desktop only for the Docker MCP server; the server runs Ollama in Docker.
- GPU access for the server container relies on nvidia-container-toolkit; if the container can't see the GPU, re-run the toolkit setup in `docs/troubleshooting.md`.