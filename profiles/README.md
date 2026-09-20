# Model Selection Profiles

Profiles control which LLM tiers are active during a session and what gets
installed where. Each profile is a shell script that exports environment
variables consumed by the install scripts, startup scripts, and OpenCode config.

Full reference: [docs/profiles.md](../docs/profiles.md).

## Quick Start

```bash
# Option 1: Source a profile directly
source profiles/dev-server-all.sh

# Option 2: Use the interactive menu (fzf if present, numbered otherwise)
./profiles/select-model.sh
```

## Profiles

Four profiles are live. Eight server profiles are parked in `parked/` (correct,
not deprecated — they target the down server; see `parked/README.md` for the
bring-back procedure).

| Profile | Purpose | Online | OpenCode default model |
|---------|---------|--------|------------------------|
| `dev-workflow-quality.sh` | qwen3:14b drives in-thread, `/plan` on the main agent (desktop) | Desktop | Qwen3 14B (desktop) |
| `dev-workflow-resident.sh` | qwen3:8b drives in-thread, 7B coder resident for no-tools code text (desktop) | Desktop | Qwen3 8B (desktop) |
| `dev-desktop-only.sh` | **Everything local on this PC** — use when the server is down | Desktop | Qwen3 8B (desktop) |
| `dev-node3.sh` | Third node, 3080 FE (onboarded 2026-09-20) | Server (+ Node3) | Qwen3 8B (node3) / server 7B fallback |

## Cloud Tier Purpose

The OpenCode Go cloud tier (`DEV_TIERS_GO`) exists specifically so you can
test any model you can't run yourself — DeepSeek V4, Qwen3.x, Kimi, GLM, and
others via `opencode-go/<model-id>`. It's backed by your Go subscription API
key (`~/.config/opencode/.secrets/opencode-go-api-key`).

Use `dev-go-only.sh` to evaluate a model before (or instead of) pulling it
locally, and `dev-full.sh` to keep cloud models on hand alongside the full
local stack.

## How It Works

Each profile auto-sources the `.env` file from the dev-docs root, then exports:

- **Tier toggles**: `DEV_TIERS_SERVER`, `DEV_TIERS_DESKTOP`, `DEV_TIERS_GO`, `DEV_TIERS_NODE3`
  → read by `server/scripts/startup.sh` and `desktop/scripts/startup.ps1`.
- **Install intent**: `DEV_SERVER_MODELS`, `DEV_DESKTOP_MODELS`, `DEV_NODE3_MODELS`
  → space-separated catalog tags/groups, consumed by `install-model.sh --profile`
  / `models.ps1 -Profile`.
- **OpenCode defaults**: `OPENCODE_MODEL`, `OPENCODE_SMALL_MODEL` and the
  per-host `OLLAMA_*_BASE_URL` that the `ollama-server`, `ollama-desktop`,
  `ollama-node3` providers read via `{env:...}`.

Variables from `.env` (SERVER_IP, DESKTOP_IP, NODE3_IP, SSH_USER) are
automatically available in every profile without re-typing.

## Choosing the OpenCode model

Profiles set OpenCode's default model. Override at runtime with the model
selector (`/models`) or a project `opencode.json`. Model IDs are
`<provider>/<tag>`:

```bash
# Desktop DeepSeek (16k context — use THIS name, not deepseek-r1:14b)
export OPENCODE_MODEL="ollama-desktop/deepseek-r1-16k"

# Server Qwen (fast autocomplete, 16k context by default)
export OPENCODE_MODEL="ollama-server/qwen2.5-coder:7b"
```

Important: on the desktop the Ollama app serves `deepseek-r1:14b` at only
4096 context unless overridden. `deepseek-r1-16k` (created by
`desktop/scripts/startup.ps1`) is the same weights with `num_ctx 16384` baked
in — always use it, or large prompts fail with `exceed_context_size_error`.

## Interactive Menu

`select-model.sh` uses `fzf` if available, otherwise falls back to a numbered
menu. It discovers `profiles/*.sh` dynamically, so it always lists exactly the
live profiles (currently four) and nothing parked. It sources the chosen
profile for you.

```bash
./profiles/select-model.sh
# then run your startup / installs
```

> On Windows, load the desktop-only profile into the current PowerShell process
> by dot-sourcing `profiles/dev-desktop-only.ps1` (the only `.ps1` wrapper);
> every other profile loads in Git bash via `source profiles/<name>.sh`.

## Creating Custom Profiles

Copy any existing profile and modify the exports:

```bash
cp profiles/dev-server-all.sh profiles/dev-experiment.sh
# edit DEV_TIERS_*, DEV_*_MODELS, and OPENCODE_* as needed
```