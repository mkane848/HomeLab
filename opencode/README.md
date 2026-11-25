# OpenCode Configuration

How OpenCode is configured for the hybrid setup.

## Config Location

Your active OpenCode config is at:

```
~/.config/opencode/opencode.jsonc
```

On Windows: `C:\Users\<username>\.config\opencode\opencode.jsonc`

## How API Keys Are Stored

API keys are stored in `~/.config/opencode/.secrets/` as plain text files,
referenced via `{file:...}` substitution in the config:

```
~/.config/opencode/
├── opencode.jsonc          # Main config (providers reference .secrets/)
├── skills/                 # Active skills (synced from <repo>\skills)
├── commands/               # Custom commands (synced from <repo>\opencode\commands)
├── agents/                 # Custom agents (synced from <repo>\opencode\agents)
├── .secrets/
│   ├── github-pat          # GitHub PAT (already set up)
│   └── opencode-go-api-key # OpenCode Go API key
```

To add your keys:

```powershell
# Windows PowerShell
"your-actual-key" | Out-File "$env:USERPROFILE\.config\opencode\.secrets\opencode-go-api-key" -NoNewline
```

## Config Hierarchy

OpenCode merges configs in this order (later overrides earlier):

1. **Remote** — organizational defaults (`.well-known/opencode`)
2. **Global** — `~/.config/opencode/opencode.jsonc` (your user prefs)
3. **Custom** — `OPENCODE_CONFIG` env var
4. **Project** — `opencode.json` in project root

## Staging the config (and copying it to another machine)

The template `opencode/global/opencode.jsonc` is staged into `~/.config/opencode/`
on the machine you run the script on. Nothing leaves the machine by default:

```powershell
# from the repo checkout
.\desktop\scripts\sync-opencode.ps1
```

1. Fills the plugin-path placeholder with this checkout's `file:///` URL.
2. Backs up a changed live `opencode.jsonc` (`opencode.jsonc.bak-yyyyMMdd-HHmmss`),
   prints what changes, writes the new one (identical: nothing written).
3. Stages `opencode/agents/*.md` and `opencode/commands/*.md`.
4. Runs `opencode debug config` and reports whether it loads and whether each plugin
   path exists (warnings only).

Copying to another machine is opt-in and only to a machine with the `opencode-client`
role in [`machines.tsv`](../machines.tsv): `-Push <machine>` (host and user from `.env`;
`-RemoteRepoRoot <path>` makes the plugin paths name the target's checkout), and
`-Secrets name1,name2` (only with `-Push`, only the files named) for API keys.
The server is a model host only and has no OpenCode client, so `-Push server` is
refused. Requires SSH access (password prompts each call, or key auth).
Restart any running OpenCode session after syncing. `node_modules/` in your local
config is intentionally skipped.

## Imported Skills (from Claude)

Skills were imported from the local Claude Code installation and vendored into
`skills/`. The plugins' agents and commands sit in `claude/imports/` as
provenance only; they are not staged (removed from `opencode/` on 2026-11-25).
Provenance and licenses live in [`claude/README.md`](../claude/README.md).

Two scripts manage the lifecycle:

```powershell
# (1) Refresh the vendored copies from Claude (after a Claude plugin update):
.\desktop\scripts\import-claude-skills.ps1

# (2) Deploy to both machines (skills -> ~/.config/opencode/skills,
#     commands -> ~/.config/opencode/commands, agents -> ~/.config/opencode/agents):
.\desktop\scripts\sync-skills.ps1            # both
.\desktop\scripts\sync-skills.ps1 -Local     # Windows only
.\desktop\scripts\sync-skills.ps1 -Server    # server only
```

Vendored in `skills/`: **73 skills** (vercel 44, render 21, ui-ux-pro-max 7,
frontend-design 1). Only **8 of them deploy globally** — `frontend-design` and
`ui-ux-pro-max`, listed in `$GLOBAL_SKILL_SOURCES` in `sync-skills.ps1`. The
rest stay in this repo and a project opts in by path:

```jsonc
"skills": { "paths": ["<path-to-this-repo>/skills/vercel"] }
```

Why: opencode advertises every installed skill's name + description in the
system prompt of **every** request (~5.5k tokens for all 73). Use
`-Scope all` to deploy everything globally, and `-Prune` when narrowing scope
or the old ones stay behind.

`opencode/commands/` has **3 commands**, all the repo's own, and
`opencode/agents/` has **none**:
- `/plan` (`plan.md`) writes `docs/implementation-tasks.md`. It runs on the main
  agent; there is no planner subagent.
- `/sandbox` runs a throwaway container.
- `/devcontainer` runs a command for LFCbot or ASoHaV in `dev-base:1`.

They follow [Factory's AGENTS.md guide](https://docs.factory.com/harness/agents-md):
the command first, then concrete rules, then a "Done when" check.

The 10 Vercel and Render agents and commands (`ai-architect`,
`deployment-expert`, `performance-optimizer`, `render-assistant`; `/bootstrap`,
`/deploy`, `/env`, `/status`, `/check-render-status`, `/deploy-to-render`) were
**deleted on 2026-11-25** (owner's call). Every session listed them, which cost
context on the 32k/64k local seats. The sync scripts never delete a live file,
so remove the old copies once on each machine that has them:

```powershell
$aside = Join-Path $env:TEMP "opencode-vendored-aside"; New-Item -ItemType Directory -Force $aside | Out-Null
$names = "agents/ai-architect","agents/deployment-expert","agents/performance-optimizer","agents/render-assistant",
         "commands/bootstrap","commands/check-render-status","commands/deploy-to-render","commands/deploy","commands/env","commands/status"
foreach ($n in $names) {
    $f = Join-Path $HOME ".config/opencode/$n.md"
    if (Test-Path -LiteralPath $f) { Move-Item -LiteralPath $f -Destination (Join-Path $aside (($n -replace '/', '-') + ".md")); "moved $n" }
}
```

Check that OpenCode no longer lists them, then delete `$aside`.

> `implement.md` and `coder.md` were **deleted 2026-09-17**. The coder subagent
> was pinned to `qwen2.5-coder-16k`, which cannot emit a parseable tool call, so
> `/implement` silently did nothing. Coding runs in-thread on the main agent.
> See `docs/troubleshooting.md` → "Agent 'says' it edited a file".

The `mcp` block in `opencode/global/opencode.jsonc` is **empty on purpose**.
Each MCP server injects its full tool schema into every request; the five that
used to live here (`vercel`, `render`, `docker`, `browser`, `postgres` — ~105
tools) were most of a 46,505-token preamble that no 16k local model can hold.
Servers now go in each **project's** `opencode.jsonc`, which deep-merges over
global (`{ "enabled": false }` switches off an inherited one). Template with
all five commented and ready: `opencode/project-override/opencode.jsonc`.

## Provider Endpoints

One provider **per llama-server host** (a provider has one `baseURL`). llama.cpp
is the only local engine since Ollama was removed on 2026-11-21 (the `ollama-*`
providers and `llamacpp-desktop` went with it; the desktop runs no models).
Endpoints come from the active profile's `LLAMACPP_*_BASE_URL` env vars via
`{env:...}` substitution:

| Provider | Endpoint (default) | Auth | Models |
|----------|--------------------|------|--------|
| OpenCode Go | `https://opencode.ai/zen/go/v1` | `{file:.secrets/opencode-go-api-key}` | any, via `opencode-go/<model-id>` |
| `llamacpp-server` | `{env:LLAMACPP_SERVER_BASE_URL}` (port 8090) | `{file:.secrets/llamacpp-api-key}` ([engine-api-keys.md](../docs/engine-api-keys.md)) | Qwen3.6 35B-A3B, Qwen3 8B, Qwen2.5 Coder 3B CPU (text only), North Mini Code, GPT-OSS 20B — the sections of `server/llamacpp/models.ini` |
| `llamacpp-node3` | `{env:LLAMACPP_NODE3_BASE_URL}` (port 8090) | `{file:.secrets/llamacpp-api-key}` | Qwen3.6 35B-A3B, Qwen3 8B — the sections of `node3/llamacpp/models.ini` |

> **No `:-default` fallbacks.** OpenCode's `{env:...}` substitution does not
> support shell-style defaults — `{env:VAR:-foo}` resolves to an empty string,
> breaking the provider with `"/chat/completions" cannot be parsed as a URL`.
> Values always come from the active profile's exported vars. On Windows the
> desktop can carry User-level defaults (`OPENCODE_MODEL`, `OPENCODE_SMALL_MODEL`,
> `LLAMACPP_SERVER_BASE_URL`) so a bare `opencode` works without a profile.

## Model ID Format

In `opencode.jsonc`, model IDs use the format `provider/model-id`, and the
model id is the section name in that host's llama-server preset, with
`limit.context` equal to the section's `c` so the client never over-promises
vs the served context:

- `opencode-go/deepseek-v4-flash` — DeepSeek via Go subscription
- `llamacpp-server/qwen3.6:35b-a3b-coding` — the main seat on the server
- `llamacpp-node3/qwen3:8b` — node3's agent seat

Adding a model (GGUF, preset section, `models/server-seats.tsv` row, this
registration, the probe): [docs/reference/config.md](../docs/reference/config.md) → "Adding a model".

## Reference Files

- `global/opencode.jsonc` — config template (already applied to `~/.config/opencode/`)
- `project-override/opencode.jsonc` — per-project override example
- `../.env.example` — shared variable reference (copy to `.env` at the repo root)

## Open Items

- **No Go model is a default.** `opencode/global/opencode.jsonc` takes `model`
  and `small_model` from the active profile (`{env:OPENCODE_MODEL}`,
  `{env:OPENCODE_SMALL_MODEL}`), and its `opencode-go` provider registers no
  model IDs. The Go models and rates on file are in `costs/go-rates.tsv`.
  (Corrected 2026-11-11: this item had named two placeholder IDs that are no
  longer in the template.)
