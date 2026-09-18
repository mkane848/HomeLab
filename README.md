# Dev Docs

Scripts and documentation for the hybrid Ubuntu/Windows development environment —
a fleet of local LLM nodes (server + desktop + future third node) driven by
OpenCode, with model installs and profiles managed from one catalog.

## Quick Start

**New here, or coming back after a break? Read [docs/start-here.md](docs/start-here.md) first** —
it is the one page that takes you from a cold machine to a working agent, with
verification at each step and the concepts explained as they come up.


Day to day, on the Windows desktop — this is the whole thing:

```powershell
cd M:\Projects\dev-docs
.\desktop\scripts\startup.ps1      # start Ollama, bake each model's context
.\desktop\scripts\opencode.ps1     # source the profile, launch OpenCode
```

`opencode.ps1` defaults to `dev-workflow-quality`; pass `-Profile <name>` for
another. Add models with `.\desktop\scripts\models.ps1 -Profile`.

On the Ubuntu server (currently down — see
[docs/server-recovery-cpu-led.md](docs/server-recovery-cpu-led.md)):

```bash
source profiles/dev-workflow-quality.sh
./server/scripts/install-model.sh --profile
./server/scripts/startup.sh
```

## What's Where

| Directory | Purpose |
|-----------|---------|
| `.env` | Shared variables (IPs, SSH user) — git-ignored, sourced by all profiles |
| `models/` | Model catalog: `catalog.tsv` (data) + `catalog.sh` (bash library) |
| `profiles/` | Model tier selection (which LLMs are online, where, and with what defaults) |
| `server/` | Ubuntu server scripts, Docker compose, systemd unit |
| `desktop/` | Windows 11 scripts (install, startup, sync) for native Ollama (Vulkan backend) |
| `opencode/` | OpenCode config templates (per-host Ollama providers + Go), commands, agents |
| `skills/` | Vendored AI skills (imported from Claude, OpenCode-compatible) |
| `claude/` | Claude import provenance + raw reference material |
| `wezterm/` | WezTerm terminal config |
| `docs/` | **[start-here](docs/start-here.md)** (read this first), plus network topology, model architecture, hardware, profiles, roadmap, troubleshooting, [lmstudio-vscode](docs/lmstudio-vscode.md) (VS Code BYOK reference + review-gate methodology) |
| `tests/` | `test-profiles.ps1` — all-profile intent/liveness/registration/schema checks, `-Bench` latency budgets. `test-toolcalls.ps1` — **does this model actually emit a tool call?** Run it before trusting any model in an agent seat |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│              Fleet: local LLM nodes + cloud                 │
│                                                             │
│  Desktop: Qwen3 8B  <- DRIVES (tool-capable, 32k ctx)       │
│           Qwen Coder 3B (small) · 7B/14B, DeepSeek-R1 14B   │
│           as no-tools models     (RX 6800 XT, Vulkan)       │
│  Server:  Qwen Coder 7B/14B, DeepSeek-R1 14B, Qwen3,        │
│           general/creative, embeddings  (4070 Ti Super)     │
│  Node3's:  Qwen3 8B, GLM4 9B  (future, RTX 3080 FE)          │
│  Cloud:   OpenCode Go (test models you can't run)           │
└─────────────────────────────────────────────────────────────┘
```

Only `qwen3` models emit parseable tool calls (3 of 10 installed pass the
probe). Everything else is a chat box that will describe edits it never made.
Probe any model with `.	ests	est-toolcalls.ps1`. Details: [docs/start-here.md](docs/start-here.md).

See [docs/model-architecture.md](docs/model-architecture.md) and
[docs/hardware.md](docs/hardware.md) for details.

## Key Files

- **`.env`** — shared variables (SERVER_IP, DESKTOP_IP, NODE3_IP placeholder, SSH_USER)
- **`models/catalog.tsv`** — every model we can run (tag, size, class, ctx, groups, hosts, desc); single source of truth for installs and OpenCode registration
- **`models/catalog.sh`** — bash library (`catalog_list`, `catalog_field`, `catalog_has_tag`, …). Sourced, never executed.
- **Install scripts** — `server/scripts/install-model.sh` (Docker) and `desktop/scripts/models.ps1` (native), both accept tags/groups/profiles
- **Profiles** — `profiles/dev-*.sh` auto-source `.env`, pick tiers + install intent + OpenCode defaults; pick via `profiles/select-model.sh`
- **Startup** — `server/scripts/startup.sh` + `server/scripts/stop.sh` and `desktop/scripts/startup.ps1`; status via `server/scripts/status.sh`
- **Tests** — `tests/test-profiles.ps1` runs every live profile against intent manifests (tier flags, tool-capable main seat, Go-default probes), OpenCode registration, host liveness; `-RoundTrip` adds capability probes + latency benchmarks, `-Bench` FAILs over-budget models (see [docs/troubleshooting.md](docs/troubleshooting.md))
- **[OpenCode template]** `opencode/global/opencode.jsonc` — providers split one-per-host: `ollama-server`, `ollama-desktop`, `ollama-node3`, `opencode-go`; redeploy with `.\desktop\scripts\sync-opencode.ps1`. Model entries must use `limit:{context,output}` — OpenCode silently drops unknown keys, and a model with no limit sends an untrimmed prompt that Ollama truncates (see [docs/troubleshooting.md](docs/troubleshooting.md)). Ships **no MCP servers**: those go in each project's own `opencode.jsonc` (`opencode/project-override/opencode.jsonc` is the template)
- **[WezTerm sync]** `.\desktop\scripts\sync-wezterm.ps1` — deploys `wezterm/wezterm.lua` to `C:\Users\<you>\.wezterm.lua`
- **Imports**: `import-claude-skills.ps1` (vendors from Claude) and `sync-skills.ps1` (deploys skills/commands/agents to Windows + server) — see [opencode/README.md](opencode/README.md)

## First Time Setup

1. Fill in `M:\Projects\dev-docs\.env` with your IPs, SSH user, and `NODE3_IP` once the node exists
2. Paste your OpenCode Go API key into `~/.config/opencode/.secrets/opencode-go-api-key`
3. Install Docker + nvidia-container-toolkit on the server (RTX 4070 Ti Super, CUDA)
4. Install Ollama on the desktop (Vulkan backend - ROCm is unavailable on gfx1030, see docs/hardware.md) and, later, on the third node
5. Source a profile and install: `install-model.sh --profile` / `.\desktop\scripts\models.ps1 -Profile`
6. `desktop/scripts/startup.ps1` bakes a per-model `num_ctx` into each tag it manages (32768 for the 14b coder and `deepseek-r1-32k`, 16384 for the rest). This gives per-model context control that the single global `OLLAMA_CONTEXT_LENGTH` cannot
7. Set firewall rules per [docs/network-topology.md](docs/network-topology.md)
8. **After copying the repo to the server** (e.g. via scp), mark scripts executable:
   ```bash
   cd ~/dev-docs
   ./make-executable.sh
   ```
   This is required because files copied from Windows lose the executable bit.

## Fresh-Install Convenience

- Nine profiles are parked in `profiles/parked/` (they need the server or the third node) — see [profiles/parked/README.md](profiles/parked/README.md). Three desktop profiles are live.
- The [roadmap](docs/roadmap.md) tracks the node3 onboarding, image pinning, and post-upgrade validation.