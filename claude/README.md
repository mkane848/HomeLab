# Claude Imports

Portable content vendored from the local Claude Code installation into dev-docs,
so it can be re-used by OpenCode (and survives on the server).

## Sources & Provenance

All imports were copied verbatim from the user's `~/.claude/plugins/` on
Windows. Versioned copies sit in:

- `skills/<source>/<skill>/` — portable SKILL.md skill dirs (OpenCode-compatible)
- `imports/<source>/` — raw reference material (agents, commands, MCP defs, README/LICENSE)

| Source | Origin | License | Import date |
|---|---|---|---|
| `frontend-design` | Anthropic official plugins<br>`github.com/anthropics/claude-plugins-official` | See `imports/frontend-design/LICENSE` | 2026-09-09 |
| `render` | Anthropic official plugins (v0.2.2) | See `imports/render/LICENSE` | 2026-09-09 |
| `vercel` | Anthropic official plugins (v0.48.0) | See `imports/vercel/LICENSE` | 2026-09-09 |
| `ui-ux-pro-max` | NextLevelBuilder<br>`github.com/nextlevelbuilder/ui-ux-pro-max-skill` | MIT | 2026-09-09 |

## What's included

- **62 skills** — `frontend-design` (1), `render` (21), `vercel` (33), `ui-ux-pro-max` (7)
- **4 agents** — vercel: `ai-architect`, `deployment-expert`, `performance-optimizer`; render: `render-assistant`
- **6 commands** — vercel: `bootstrap`, `deploy`, `env`, `status`; render: `check-render-status`, `deploy-to-render`
- **2 MCP servers** (opt-in, need runtime auth):
  - vercel: `https://mcp.vercel.com` (OAuth)
  - render: `https://mcp.render.com/mcp` (OAuth)
  Raw definitions in `imports/vercel/mcp.json` and `imports/render/mcp.json`.

## What was intentionally excluded

Claude-plugin infrastructure that doesn't port to OpenCode:

- `hooks/` — plugin hooks (different system hooks in OpenCode)
- `src/`, `tests/`, `scripts/`, `generated/` — build/test/benchmark internals
- `.github/` workflow files, `_conventions.md` command helper
- `*.tmpl` agent/command templates

## Re-importing

If Claude plugins update, re-run the importer to refresh the vendored copies:

```powershell
cd M:\Projects\dev-docs
.\desktop\scripts\import-claude-skills.ps1
```

Scrapes the active installed versions via
`~/.claude/plugins/installed_plugins.json`, so it tracks upgrades automatically.
Run it from Windows (where Claude lives). Then re-sync to push the refresh out:

```powershell
.\desktop\scripts\sync-skills.ps1   # both machines
```

## Naming collisions

Skills are flattened into a single `~/.config/opencode/skills/` namespace on
deploy. The importer keeps them under `skills/<source>/` in dev-docs;
`sync-skills.ps1` warns if two sources ever ship the same skill name.

## Relationship to dev-docs

- `skills/` and `opencode/commands|agents` are the **canonical deployed artifacts**
- `imports/` is raw provenance (reference only; not deployed)
- The MCP comment block in `opencode/global/opencode.jsonc` is the deploy point
  for the two cloud MCP servers