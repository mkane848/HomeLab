#!/usr/bin/env bash
# dev-workflow-quality.sh - agentic desktop loop (16GB RX 6800 XT)
#
# Main agent = qwen3:8b. It reads, plans, edits and verifies directly
# in-thread - coding NEVER goes through delegation.
#
# WHY NOT qwen2.5-coder:14b (it used to be the main agent here):
# it cannot call tools. Probed against /api/chat with a tool schema
# (tests/test-toolcalls.ps1), only 1 of 8 installed models returns a
# structured tool_calls entry - qwen3:8b. qwen2.5-coder (3b/7b/14b) prints the
# call as chat text; deepseek-r1 ignores the tool and answers in prose. A
# model that fails that probe is a chat box in an agent seat: it will report
# edits it never made. The 14b stays registered for deliberate no-tools use
# (code text, explanation, review) - it is not the boss any more.
#
# Bonus: qwen3:8b prefills ~670-900 tok/s vs the 14b's ~200, so first-turn
# latency on an ~11.4k-token preamble drops from minutes to well under one.
#
# Workflow:
#   /plan <scope>   -> qwen3:8b writes/updates docs/implementation-tasks.md
#   then just tell the main agent: "execute task #N from docs/implementation-tasks.md"
# There is no /implement: its coder subagent was pinned to a model that could
# not call tools, so it silently did nothing. Removed 2026-09-17.
#
# VRAM (MEASURED at runtime via /api/ps, not catalog disk size - weights + KV
# cache + compute buffers, with FLASH_ATTENTION=1 + KV_CACHE_TYPE=q8_0):
#   qwen3:8b          @16k ctx =  5.93 GB   main agent
#   qwen2.5-coder:3b  @16k ctx =  2.26 GB   small model (titles/summaries)
#   ------------------------------------------------
#   resident total             =  8.19 GB of ~14.8 GB usable
#
# Headroom is deliberate: ~6.6 GB free means the 14b (11.27 GB) can still be
# swapped in for a review pass, and nothing the small model does evicts the
# main agent. The old comment here budgeted from catalog DISK sizes and was
# wrong by ~3 GB, which is why the 14b used to get evicted on every
# title/summary call and pay a 14.1 s reload afterwards.
#
# deepseek-r1-32k (~12.3 GB) swaps in only during /plan, then unloads.
#
# Requires OLLAMA_FLASH_ATTENTION=1 + OLLAMA_KV_CACHE_TYPE=q8_0 (User env) -
# without them the 14b needs 14.5 GB at 32k and nothing else fits beside it.
#
# Needs two downloads on first use: qwen2.5-coder:14b (~9 GB) and
# qwen2.5-coder:3b (~1.9 GB). startup.ps1 auto-pulls missing bake targets and
# bakes the per-model num_ctx (32768 for the 14b, 16384 for the rest).

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=false
export DEV_TIERS_DESKTOP=true
export DEV_TIERS_GO=false
export DEV_TIERS_NODE3=false

# Explicit tags. qwen3:14b is the main seat, qwen3:8b the lighter alternative,
# qwen2.5-coder:3b the small model. The coder/deepseek tags are kept installed
# as no-tools models for code text and review.
export DEV_DESKTOP_MODELS="qwen3:14b qwen3:8b qwen2.5-coder:3b qwen2.5-coder:7b qwen2.5-coder:14b deepseek-r1:14b"

# Running on the box itself - localhost, immune to LAN/IP changes
export OLLAMA_DESKTOP_URL="http://localhost:11434"
export OLLAMA_DESKTOP_BASE_URL="${OLLAMA_DESKTOP_BASE_URL:-http://localhost:11434/v1}"

export OPENCODE_MODEL="ollama-desktop/qwen3:8b"
export OPENCODE_SMALL_MODEL="ollama-desktop/qwen2.5-coder:3b"

# Start the local dev stack (Postgres + Redis) with startup.ps1 at login.
export DEV_DOCKER_STACK=true

echo "[profile] Workflow Quality: qwen3:8b drives in-thread (32k), /plan on demand"