#!/usr/bin/env bash
# dev-workflow-quality.sh - agentic desktop loop (16GB RX 6800 XT)
#
# Main agent = qwen3.6:35b-a3b-coding. It reads, plans, edits and verifies
# directly in-thread - coding NEVER goes through delegation.
#
# WHY qwen3.6 (re-seated 2026-10-03, docs/main-seat-trial.md): it won the
# main-seat trial on loose, human-language prompts (3 CLEAN, 1 QUALIFIED, 0
# FAIL; the qwen3:14b control FAILed both tasks it ran) and leads the task
# benchmark (docs/roadmap.md -> "Executor
# standings"). It passes tests/test-toolcalls.ps1 with a structured tool_calls
# entry. qwen3:14b, the seat from 2026-09-17 to 2026-10-03, stays installed and
# registered.
#
# Trade-offs:
#   - It does not fit on the GPU. A 35B MoE (3B active) at 64k: 21.13 GB in
#     total, of which Ollama puts 12.51 GB (all it can) on the GPU and runs
#     the rest from system RAM. Measured via /api/ps, 2026-10-03.
#   - A fresh preamble prefill is slow (~70 s for the first request of the
#     first session); later sessions reuse the prompt cache as long as the
#     model stays loaded (17-23 s first turns, measured).
#   - Keep-alive is Ollama's 5m default: idle past 5 minutes and the next
#     reply pays a reload plus a full re-prefill (2-3.5 min measured on
#     2026-10-01). OLLAMA_KEEP_ALIVE is an open owner decision (roadmap).
#   - The companion runs on the CPU (below). The VRAM measurement was taken on
#     a clean desktop (no browser, WSL and Docker stopped); with the dev stack
#     (DEV_DOCKER_STACK, WSL capped at 12 GB) it is unmeasured.
#   - Watch a session for repeated `<- Write` lines; if you see them, drop
#     back to qwen3:8b, which stays registered and seats fine.
#
# Workflow:
#   /plan <scope>   -> main agent writes/updates docs/implementation-tasks.md
#   then just tell the main agent: "execute task #N from docs/implementation-tasks.md"
# There is no /implement: its coder subagent was pinned to a model that could
# not call tools, so it silently did nothing. Removed 2026-09-17.
#
# Memory (MEASURED at runtime via /api/ps, not catalog disk size, with
# FLASH_ATTENTION=1 + KV_CACHE_TYPE=q8_0):
#   qwen3.6:35b-a3b-coding @64k = 21.13 GB (12.51 GB VRAM, rest RAM)  main agent
#   qwen2.5-coder-3b-cpu   @16k =  2.27 GB (0 VRAM, all RAM)    small model (titles)
#
# Why the companion is on the CPU: qwen3.6 takes every byte of VRAM it can,
# so the GPU qwen2.5-coder:3b evicted it at each session start (titles), and
# it reloaded a minute later. qwen2.5-coder-3b-cpu is the same 3b with
# num_gpu 0 baked in by startup.ps1. Second experiment, 2026-10-03: 3
# sessions, 0 evictions, qwen3.6 loaded once, titles in 3.4-14.8 s.
#
# Requires OLLAMA_FLASH_ATTENTION=1 + OLLAMA_KV_CACHE_TYPE=q8_0 (User env).
#
# Needs downloads on first use: qwen3.6:35b-a3b-coding (~23 GB) and
# qwen2.5-coder:3b (~1.9 GB). startup.ps1 auto-pulls missing bake targets,
# bakes the per-model num_ctx (65536 for qwen3.6) and derives the CPU
# companion from the 3b.

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=false
export DEV_TIERS_DESKTOP=true
export DEV_TIERS_GO=false
export DEV_TIERS_NODE3=false

# Explicit tags. qwen3.6 is the main seat, qwen3:14b the former seat, qwen3:8b
# the lighter alternative, qwen2.5-coder:3b the base of the CPU companion
# (qwen2.5-coder-3b-cpu is derived by startup.ps1, not pulled). The
# coder/deepseek tags are kept installed as no-tools models for code text and
# review.
export DEV_DESKTOP_MODELS="qwen3.6:35b-a3b-coding qwen3:14b qwen3:8b qwen2.5-coder:3b qwen2.5-coder:7b qwen2.5-coder:14b deepseek-r1:14b"

# Running on the box itself - localhost, immune to LAN/IP changes
export OLLAMA_DESKTOP_URL="http://localhost:11434"
export OLLAMA_DESKTOP_BASE_URL="${OLLAMA_DESKTOP_BASE_URL:-http://localhost:11434/v1}"

export OPENCODE_MODEL="ollama-desktop/qwen3.6:35b-a3b-coding"
export OPENCODE_SMALL_MODEL="ollama-desktop/qwen2.5-coder-3b-cpu"

# Don't let opencode auto-load ~/.claude/skills into every request (10 synced
# SKILL.md files = ~1.5k standing tokens of the preamble; measured 16851 total
# vs the ~11.4k baseline). Lean global scope; projects opt in via skills.paths.
export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1

# Start the local dev stack (Postgres + Redis) with startup.ps1 at login.
export DEV_DOCKER_STACK=true

echo "[profile] Workflow Quality: qwen3.6 drives in-thread (64k), CPU companion, /plan on demand"
