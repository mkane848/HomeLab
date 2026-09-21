#!/usr/bin/env bash
# dev-workflow-quality.sh - agentic desktop loop (16GB RX 6800 XT)
#
# Main agent = qwen3:14b. It reads, plans, edits and verifies directly
# in-thread - coding NEVER goes through delegation.
#
# WHY qwen3:14b (re-seated 2026-09-17): it returns a structured tool_calls
# entry under tests/test-toolcalls.ps1 - the same probe qwen2.5-coder
# (3b/7b/14b) and deepseek-r1 fail by printing the call as chat text. It is
# the largest tool-capable model this GPU holds (11.03 GB @ 32k, 100% on GPU,
# 48.9 tok/s, measured) and it holds loose, human-language intent better than
# the 8b - the goal is a Claude Code / Codex-like loop you prompt normally.
#
# Trade-offs (see docs/troubleshooting.md -> "repeated calls"):
#   - On one real task it issued 6 write calls for a single request (8b: 1).
#     Watch a session for repeated `<- Write` lines; if you see them, drop
#     back to qwen3:8b, which stays registered and seats fine.
#   - Slower than the 8b (48.9 vs 79.8 tok/s), accepted for the intent gain.
#   - No swap-in reviews any more: main (11.03) + 3b (2.26) = 13.29 GB of
#     ~14.8 GB usable. Loading qwen2.5-coder:14b or deepseek-r1-32k evicts
#     the main agent (cold reload + lost prompt cache) every time.
#
# Workflow:
#   /plan <scope>   -> main agent writes/updates docs/implementation-tasks.md
#   then just tell the main agent: "execute task #N from docs/implementation-tasks.md"
# There is no /implement: its coder subagent was pinned to a model that could
# not call tools, so it silently did nothing. Removed 2026-09-17.
#
# VRAM (MEASURED at runtime via /api/ps, not catalog disk size - weights + KV
# cache + compute buffers, with FLASH_ATTENTION=1 + KV_CACHE_TYPE=q8_0):
#   qwen3:14b         @32k ctx = 11.03 GB   main agent
#   qwen2.5-coder:3b  @16k ctx =  2.26 GB   small model (titles/summaries)
#   ------------------------------------------------
#   resident total             = 13.29 GB of ~14.8 GB usable
#
# Headroom (~1.5 GB) is deliberate: nothing the small model does evicts the
# main agent. The old comment here budgeted from catalog DISK sizes and was
# wrong by ~3 GB, which is why the 14b used to get evicted on every
# title/summary call and pay a 14.1 s reload afterwards.
#
# Requires OLLAMA_FLASH_ATTENTION=1 + OLLAMA_KV_CACHE_TYPE=q8_0 (User env) -
# without them the 14b needs 14.5 GB at 32k and nothing else fits beside it.
#
# Needs two downloads on first use: qwen3:14b (~9.3 GB) and
# qwen2.5-coder:3b (~1.9 GB). startup.ps1 auto-pulls missing bake targets and
# bakes the per-model num_ctx (32768 for qwen3:14b/8b, qwen2.5-coder:14b and
# deepseek-r1-32k; 16384 for the rest).

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

export OPENCODE_MODEL="ollama-desktop/qwen3:14b"
export OPENCODE_SMALL_MODEL="ollama-desktop/qwen2.5-coder:3b"

# Don't let opencode auto-load ~/.claude/skills into every request (10 synced
# SKILL.md files = ~1.5k standing tokens of the preamble; measured 16851 total
# vs the ~11.4k baseline). Lean global scope; projects opt in via skills.paths.
export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1

# Start the local dev stack (Postgres + Redis) with startup.ps1 at login.
export DEV_DOCKER_STACK=true

echo "[profile] Workflow Quality: qwen3:14b drives in-thread (32k), /plan on demand"