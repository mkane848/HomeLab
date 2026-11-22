# Model Architecture

> **Rewritten 2026-11-22** for a llama.cpp-only fleet: Ollama was removed on 2026-11-21, and the desktop runs no
> models. The earlier three-tier page (Qwen Coder on the server, DeepSeek-R1 on the desktop, catalog groups) predated
> the 2026-09-17 tool-calling finding and was marked stale; it is in git history.
>
> Sources of truth: which models can be agent seats → [tool-calling.md](tool-calling.md); what each live profile
> seats → [profiles.md](profiles.md); measured runtime VRAM → [hardware.md](hardware.md).

## Overview

```
                 ┌─────────────────────────────────────────────┐
                 │  DESKTOP: OpenCode client, harness run host │
                 │  (runs no models since 2026-11-21)          │
                 └──────┬──────────────────┬───────────────┬───┘
                        │ LAN              │ LAN           │ internet
                        ▼                  ▼               ▼
┌─────────────────────────────┐ ┌──────────────────────┐ ┌───────────────┐
│ SERVER (CUDA, 4070 Ti Super)│ │ NODE3 (CUDA, 3080 FE)│ │  OpenCode Go  │
│ llama-server, Docker, :8090 │ │ llama-server, :8090  │ │ hosted models │
│ qwen3.6:35b-a3b-coding      │ │ qwen3:8b             │ │               │
│ + qwen2.5-coder-3b-cpu      │ │ + qwen3.6 on demand  │ │               │
│ + qwen3:8b, gpt-oss, ...    │ │                      │ │               │
└─────────────────────────────┘ └──────────────────────┘ └───────────────┘
```

Every model host runs llama.cpp's `llama-server` in router mode, and OpenCode reaches each through one provider per
host (`llamacpp-server`, `llamacpp-node3`); the hosted tier is the `opencode-go` provider. Which host runs what is
decided by the active **profile** — see [profiles.md](profiles.md).

## Nodes

| Host | Engine | GPU | Seats | Profile |
|------|--------|-----|-------|---------|
| Server | llama-server in Docker (`server/docker/docker-compose.llamacpp.yml`), preset `server/llamacpp/models.ini` | RTX 4070 Ti Super 16 GB (+ CPU for `qwen3.6`'s experts and the 3b) | `qwen3.6:35b-a3b-coding` (main seat), `qwen2.5-coder-3b-cpu` (small model), `qwen3:8b`, `gpt-oss:20b`, `north-mini-code`, the household vision seats — `models/server-seats.tsv` | `dev-workflow-server-llamacpp` (default) |
| node3 | native llama-server (b11562), preset `node3/llamacpp/models.ini`; 127.0.0.1 until its LAN firewall rule | RTX 3080 FE 10 GB | `qwen3:8b`, `qwen3.6:35b-a3b-coding` on demand | `dev-node3` |
| Desktop | none | RX 6800 XT 16 GB, not used for models | — (OpenCode client, harness run host) | — |
| Cloud | OpenCode Go API (`opencode.ai/zen/go/v1`) | N/A | DeepSeek V4, Qwen3.x, Kimi, GLM and more | `dev-go-only` (parked) |

## Model selection

| Task | Seat | Why |
|------|------|-----|
| Everyday coding, `/plan` → execute | `qwen3.6:35b-a3b-coding` on the server | the main seat; leads the real-repo task benchmark ([roadmap.md](roadmap.md) → "Executor standings") |
| Lighter or second seat | `qwen3:8b` on node3 (or the server) | tool-capable, fits 10 GB |
| Session titles | `qwen2.5-coder-3b-cpu` | on the CPU, so it never competes with the main seat for VRAM; cannot call tools |
| A model you can't host locally | OpenCode Go | hosted; ask before sending repos or spending usage |
| Embeddings | none today | `nomic-embed-text` / `mxbai-embed-large` were Ollama-only and went with it; a future llama-server `--embedding` seat ([reference/config.md](reference/config.md)) |

Only a seat that passes the tool-call probe (`.\tests\test-toolcalls.ps1 -Engine llamacpp -EngineHost
http://SERVER_IP:8090 -Model <tag>`) and shows task-loop evidence may be an agent seat. OpenCode model IDs follow
`<provider>/<tag>`: `llamacpp-server/qwen3.6:35b-a3b-coding`, `llamacpp-node3/qwen3:8b`. Adding a model:
[reference/config.md](reference/config.md) → "Adding a model".
