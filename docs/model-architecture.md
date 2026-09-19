# Model Architecture

> **⚠ STALE — written before the 2026-09-17 tool-calling finding. Do not use
> this page to choose a seat.**
>
> This page predates the measurement that only the qwen3 family and
> `devstral:24b` emit parseable tool calls. It still presents
> `deepseek-r1-16k` and the `qwen2.5-coder` family as working seats; none of
> them can call a tool, and an agent seated on one will claim edits it never
> made. It also never mentions `qwen3:14b`, which is the actual default main
> seat.
>
> Current sources of truth:
> - **Which models can be agent seats** → [start-here.md](start-here.md) →
>   "not every model can use tools", and `tests/results/toolcalls-0.34.1.txt`
> - **What each live profile seats** → [profiles.md](profiles.md)
> - **Measured runtime VRAM** → [hardware.md](hardware.md)
>
> Kept for the host/tier layout and the cloud tier, which are still accurate.
> Rewriting it is tracked in [roadmap.md](roadmap.md).

Three-tier LLM deployment across server, desktop, and (optionally) cloud. After the Sep 2026 server upgrade the fleet gained a second capable GPU host.

## Overview

```
                     ┌────────────────────────────────────────┐
                     │    WezTerm Terminal UI (OpenCode CLI)  │
                     └────┬───────────────────────┬───────────┘
                          │                       │
          Local LAN (X4)  │        Local Server   │           Cloud API
                          ▼                       ▼               ▼
┌──────────────────────────────┐ ┌───────────────────┐ ┌───────────────┐
│    DESKTOP (Vulkan, 6800XT)  │ │  SERVER (CUDA,     │ │  CLOUD AGENT  │
│   native Windows Ollama      │ │   4070 Ti Super)   │ │  OpenCode Go  │
│   DeepSeek-R1 14B (16k ctx)  │ │  Qwen Coder 7B/14B │ │  (open models)│
│   + qwen2.5-coder:7b         │ │  DeepSeek-R1 14B   │ │ (Low-cost,    │
│   + glm4:9b                  │ │  Qwen3 8B/14B      │ │  reliable)    │
│   + embed models             │ │  + general/creative│ │               │
└──────────────────────────────┘ └───────────────────┘ └───────────────┘
                  ┌───────────────────────────┐
                  │   THIRD NODE (future)      │
                  │   RTX 3080 FE, CUDA 10GB  │
                  │   qwen3:8b + glm4:9b      │
                  └───────────────────────────┘
```

Every Ollama-capable machine is a node, reachable by OpenCode through a per-host `ollama-*` provider (`ollama-server`, `ollama-desktop`, `ollama-node3`). Which node runs what is decided by the active **profile** — see `docs/profiles.md`.

## Nodes

| Tier | Host | GPU | Models (catalog groups) | Default via profile |
|------|------|-----|--------------------------|---------------------|
| Local coder | Server (Docker Ollama, CUDA) | 4070 Ti Super 16 GB | `autocomplete` (Qwen 7B) · `coder` (Qwen 14B) · `reasoner` (DeepSeek 14B, Qwen3) · `general creative embed` | `dev-coder`, `dev-server-all` |
| Local reasoner | Desktop (native Ollama, Vulkan) | RX 6800 XT 16 GB | `reasoner` (DeepSeek-R1 14B via `deepseek-r1-16k` bake) · Qwen Coder 7B · GLM4 9B · embeddings | `dev-local-only` |
| Future node | Third node (CUDA) | RTX 3080 FE 10 GB | `general embed` (Qwen3 8B, GLM4 9B) | `dev-node3` |
| Cloud | OpenCode Go API | N/A | DeepSeek V4, Qwen3.x, Kimi, GLM + more | `dev-go-only`, `dev-full` |

## Tier Details

### Tier 1: Local Coder (Server — Qwen 2.5 Coder 7B / 14B)

| Property | Value |
|----------|-------|
| Models | `qwen2.5-coder:7b`, `qwen2.5-coder:14b` |
| Host | Ubuntu server, Docker container |
| GPU | RTX 4070 Ti Super (16 GB VRAM) — was GTX 1070 |
| Purpose | Fast, free, infinite autocomplete + mid-weight coding |
| Cost | $0 |
| Latency | ~50–150ms (7B); ~150–400ms (14B) |

**Best for**: Code completion, quick suggestions, autocomplete, straightforward edits.
The 14B does most single-file work comfortably at full 16k context.

### Tier 2: Local Reasoner (Desktop — DeepSeek-R1 14B)

| Property | Value |
|----------|-------|
| Model | `deepseek-r1-16k` (derived from `deepseek-r1:14b` via Modelfile) |
| Host | Windows 11, native Ollama on the Vulkan backend (not ROCm - see docs/hardware.md) |
| GPU | RX 6800 XT (16 GB VRAM) |
| Purpose | Deep chain-of-thought, multi-file editing |
| Cost | $0 |
| Latency | ~200–500ms |
| Context | 16384 (baked in via `PARAMETER num_ctx`; created by `desktop/scripts/startup.ps1`) |

**Best for**: Architectural decisions, debugging complex issues, planning multi-file refactors.
Since the server upgrade, `dev-server-all` can run this same model on the server instead (CUDA), freeing the desktop.

### Tier 3: Cloud Agent (OpenCode Go)

| Property | Value |
|----------|-------|
| Models | DeepSeek V4, Qwen3.x, Kimi, GLM, and more |
| Host | OpenCode Go API (`opencode.ai/zen/go/v1`) |
| GPU | N/A |
| Purpose | Test models you can't run locally + reliable cloud coding |
| Cost | Subscription |
| Latency | ~1–3s |

**Best for**: Evaluating a model before pulling it locally, large feature generation,
complex refactors, final review.

## Model Selection Guide

| Task | Recommended Tier | Why |
|------|------------------|-----|
| Autocomplete | Qwen 7B (server) | Fast, free, no latency |
| Single-file coding at 16k | Qwen 14B (server) | Deep context, fast on CUDA |
| Bug investigation | DeepSeek (Tier 2) | Good reasoning, local, free |
| Testing a new model | OpenCode Go (Tier 3) | Run models you can't host locally |
| Multi-file refactor | Go models (Tier 3) | High quality open models |
| Semantic search / embeddings | Server embed group | `nomic-embed-text`, `mxbai-embed-large` |
| Architecture planning | DeepSeek (Tier 2) or Go | Deep thinking |
| Code review | Go models (Tier 3) | Thorough analysis |

## Switching Between Tiers

Use profiles to select which tiers are active (see `docs/profiles.md`):

```bash
bash profiles/select-model.sh          # menu-driven
source profiles/dev-server-all.sh      # coder + reasoner on the server
source profiles/dev-local-only.sh      # Qwen server + DeepSeek desktop, zero cloud
source profiles/dev-embeddings.sh      # autocomplete + embeddings for search work
source profiles/dev-go-only.sh         # Qwen + OpenCode Go for cloud testing
```

The active profile sets environment variables that the startup scripts and
OpenCode config use to determine which models are available. OpenCode model IDs
follow `<host>/<tag>`: `ollama-server/qwen2.5-coder:14b`, `ollama-desktop/deepseek-r1-16k`.