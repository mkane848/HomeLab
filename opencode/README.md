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
├── skills/                 # Active skills (synced from dev-docs\skills)
├── commands/               # Custom commands (synced from dev-docs\opencode\commands)
├── agents/                 # Custom agents (synced from dev-docs\opencode\agents)
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

## Syncing to the Ubuntu Server

Once your Windows config is where you want it, push it (and your skills/agents
scaffolding) to the server in one shot:

```powershell
# from M:\Projects\dev-docs
.\desktop\scripts\sync-opencode.ps1
```

This uses `SSH_USER` and `SERVER_IP` from the dev-docs `.env`, then:
1. Creates `~/.config/opencode/{.secrets,skills,agents,tools,commands,plugins,themes}` on the server
2. Copies `opencode.jsonc`
3. Copies everything in `.secrets/`

> Note: skills/agents/etc. directories are created empty on the server — but
> see **Imported Skills** below for the script that populates them from
> `dev-docs`. `node_modules/` in your local config is intentionally skipped.
>
> Requires SSH access (password prompts each call, or set up key auth with
> `ssh-copy-id`). Restart any running OpenCode session after syncing.

## Imported Skills (from Claude)

Skills, commands, and agents were imported from the local Claude Code
installation and vended into dev-docs (`skills/`, `opencode/commands/`,
`opencode/agents/`). Provenance and licenses live in
[`claude/README.md`](../claude/README.md).

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

Vendored in `skills/`: **65 skills** (vercel 33, render 21, ui-ux-pro-max 7,
frontend-design 1). Only **8 of them deploy globally** — `frontend-design` and
`ui-ux-pro-max`, listed in `$GLOBAL_SKILL_SOURCES` in `sync-skills.ps1`. The
rest stay in this repo and a project opts in by path:

```jsonc
"skills": { "paths": ["M:/Projects/dev-docs/skills/vercel"] }
```

Why: opencode advertises every installed skill's name + description in the
system prompt of **every** request (~5.5k tokens for all 65). Use
`-Scope all` to deploy everything globally, and `-Prune` when narrowing scope
or the old ones stay behind.

Current `opencode/` has **9 commands** and **5 agents**. `plan.md` +
`planner.md` are the `/plan` flow; the rest are Vercel/Render imports.

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

One provider **per Ollama host** (a single ollama provider can only reach one
`baseURL`). Endpoints come from the active profile's `OLLAMA_*_BASE_URL` env
vars via `{env:...}` substitution:

| Provider | Endpoint (default) | Auth | Models |
|----------|--------------------|------|--------|
| OpenCode Go | `https://opencode.ai/zen/go/v1` | `{file:.secrets/opencode-go-api-key}` | any, via `opencode-go/<model-id>` |
| `ollama-server` | `{env:OLLAMA_SERVER_BASE_URL}` | None | Qwen Coder 7B/14B, DeepSeek-R1 14B, Qwen3 8B/14B, GLM4 9B, Gemma3 12B, Codestral, GPT-OSS 20B, QwQ 32B |
| `ollama-desktop` | `{env:OLLAMA_DESKTOP_BASE_URL}` | None | DeepSeek-R1 16k (baked) + base 14b, Qwen Coder 7B (+ `-16k` bake), Qwen Coder 14B, Qwen3 8B, GLM4 9B |
| `ollama-node3` | `{env:OLLAMA_NODE3_BASE_URL}` (set once `NODE3_IP` exists) | None | Qwen3 8B, GLM4 9B |

> **No `:-default` fallbacks.** OpenCode's `{env:...}` substitution does not
> support shell-style defaults — `{env:VAR:-foo}` resolves to an empty string,
> breaking the provider with `"/chat/completions" cannot be parsed as a URL`.
> Values always come from the active profile's exported vars. On Windows the
> desktop has User-level defaults (`OPENCODE_MODEL`, `OPENCODE_SMALL_MODEL`,
> `OLLAMA_DESKTOP_BASE_URL`) so OpenCode works without sourcing a profile.

## Model ID Format

In `opencode.jsonc`, model IDs use the format `provider/model-id`. The
registered IDs mirror `models/catalog.tsv` (context windows baked in so the
client never over-promises vs the served context):

- `opencode-go/deepseek-v4-flash` — DeepSeek via Go subscription
- `ollama-server/qwen2.5-coder:14b` — Qwen Coder 14B on the server
- `ollama-desktop/deepseek-r1-16k` — the desktop bake with num_ctx 16384
  (use this, NOT `deepseek-r1:14b`, for desktop reasoning)

After adding a model to the catalog, register it in the appropriate provider
block so it appears in OpenCode's `/models`.

## Reference Files

- `global/opencode.jsonc` — config template (already applied to `~/.config/opencode/`)
- `project-override/opencode.jsonc` — per-project override example
- `.env.example` — shared variable reference (actual `.env` is in dev-docs root)

## Open Items

- **Default Go model IDs are placeholders.** `opencode/global/opencode.jsonc`
  currently defaults to `opencode-go/deepseek-v4-flash` (model) and
  `opencode-go/mimo-v2.5` (small_model), taken from the Go docs as examples —
  not confirmed against the user's subscription. Revisit once the user picks
  their actual preferred Go models and update the template (then re-apply if
  the live `~/.config/opencode/opencode.jsonc` should change too).
