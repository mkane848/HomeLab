# HomeLab

A documented homelab: a hybrid Ubuntu-server / Windows-desktop fleet running
local LLMs (Ollama), driven day to day from **both**
[OpenCode](https://opencode.ai) (terminal agent) **or** VS Code's native
Copilot Chat via BYOK (bring-your-own-key) — same fleet tested with two interfaces. Model installs and per-machine profiles
are managed from one catalog. Written up for other hobbyists — hardware
notes, a live-fire hardware recovery log, VRAM/tool-calling benchmarks
measured on real models, and a small research thread on whether a local LLM
can act as a code-review gate.


## Start here

New to the repo? **[docs/README.md](docs/README.md)** is the index — it groups
everything below by theme. A few entry points if you want to jump straight in:

- **[docs/start-here.md](docs/start-here.md)** — cold machine to a working agent via OpenCode, step by step.
- **[docs/lmstudio-vscode.md](docs/lmstudio-vscode.md)** — same fleet, driven from VS Code instead: BYOK setup for LM Studio and Ollama side by side.
- **[docs/server-recovery-cpu-led.md](docs/server-recovery-cpu-led.md)** — a live BIOS-flash recovery log (solid CPU LED, no POST) written as the debugging happened, not after.
- **[docs/hardware.md](docs/hardware.md)** — the fleet's hardware and measured VRAM/throughput numbers per model, not catalog-disk-size guesses.
- **[docs/review-gate/README.md](docs/review-gate/README.md)** — can a local LLM catch what it's told to look for in a code review? A small experiment with real (mixed) results.

## Two ways to talk to the fleet

Both are genuinely in use, not one "official" path and one experiment:

| | OpenCode | VS Code |
|---|---|---|
| Interface | Terminal (WezTerm) | Native Copilot Chat, agent mode |
| Backends | Ollama (server + desktop) + OpenCode Go (cloud) | Ollama (desktop) + LM Studio, side by side |
| Model picker | Profiles (`profiles/dev-*.sh`) pin a seat per host | VS Code's model picker — swap per message |
| Best for | Scripted, repeatable sessions; `/plan` → task list → execute | Quick swaps between local backends; the [review-gate](docs/review-gate/README.md) research |
| Setup | [docs/start-here.md](docs/start-here.md) | [docs/lmstudio-vscode.md](docs/lmstudio-vscode.md) |

## Quick Start

Day to day, on the Windows desktop — this is the whole thing:

```powershell
cd dev-docs
.\desktop\scripts\startup.ps1      # start Ollama, bake each model's context
.\desktop\scripts\opencode.ps1     # source the profile, launch OpenCode
```

`opencode.ps1` defaults to `dev-workflow-quality`; pass `-Profile <name>` for
another. Add models with `.\desktop\scripts\models.ps1 -Profile`.

Prefer VS Code? Skip straight to [docs/lmstudio-vscode.md](docs/lmstudio-vscode.md) —
`startup.ps1` above still applies (it's what starts Ollama and bakes context),
you just don't need `opencode.ps1`.

On the Ubuntu server:

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
| `skills/` | Vendored AI skills (imported from Claude, OpenCode-compatible) — third-party, own licenses, not part of the homelab story |
| `claude/` | Claude import provenance + raw reference material |
| `wezterm/` | WezTerm terminal config |
| `docs/` | **[README](docs/README.md)** (start here), grouped by getting-started / hardware & network / war stories / the review-gate research thread / roadmap |
| `tests/` | `test-profiles.ps1` — all-profile intent/liveness/registration/schema checks, `-Bench` latency budgets. `test-toolcalls.ps1` — **does this model actually emit a tool call?** Run it before trusting any model in an agent seat |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│              Fleet: local LLM nodes + cloud                 │
│                                                             │
│  Desktop: Qwen3 14B <- DRIVES (tool-capable, 32k ctx)       │
│           Qwen3 8B = lighter seat · Qwen Coder 3B (small)   │
│           Coder 7B/14B, DeepSeek-R1 14B = no-tools models   │
│                                  (RX 6800 XT, Vulkan)       │
│  Server:  Qwen Coder 7B/14B, DeepSeek-R1 14B, Qwen3,        │
│           general/creative, embeddings  (4070 Ti Super)     │
│  Node3:   Qwen3 8B (agent seat), GLM4 9B (no-tools)         │
│           + embeddings (RTX 3080 FE, live since 2026-09-20) │
│  Cloud:   OpenCode Go (test models you can't run)           │
└─────────────────────────────────────────────────────────────┘
```

Only the `qwen3` family and `devstral:24b` emit parseable tool calls (5 of 13
installed pass the probe, measured on Ollama 0.34.1). Everything else is a chat
box that will describe edits it never made.
Probe any model with `.\tests\test-toolcalls.ps1`. Details: [docs/start-here.md](docs/start-here.md).

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

1. Fill in `.env` (repo root) with your IPs, SSH user, and `NODE3_IP` once a third node exists
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

- Eight profiles are parked in `profiles/parked/` (they need the server) — see [profiles/parked/README.md](profiles/parked/README.md). Four profiles are live (three desktop + `dev-node3`).
- The [roadmap](docs/roadmap.md) tracks third-node onboarding, image pinning, and post-upgrade validation.

## License

MIT (see [LICENSE](LICENSE)) for the scripts and documentation in this repo.
Vendored third-party skill packages under `skills/` and `claude/imports/`
keep their own licenses — see [claude/README.md](claude/README.md) for
provenance.
