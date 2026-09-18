#!/usr/bin/env bash
# dev-workflow-resident.sh - qwen3 drives; 7b coder kept resident as a no-tools model
#
# Fits the whole trio's day-to-day work in VRAM with no swaps.
#
# VRAM (MEASURED via /api/ps with OLLAMA_FLASH_ATTENTION=1 + KV q8_0 - these
# are runtime figures: weights + KV cache + compute buffers, NOT the catalog's
# disk sizes, which undercount by 1-3 GB):
#   qwen3:8b          @16k  = 5.93 GB  main orchestrator - disciplined tool
#                                      loop, thinking mode on tap
#   qwen2.5-coder-16k @16k  = 4.81 GB  no-tools code/review model, on tap
#   ----------------------------------------------------------------
#   normal-work residency   = 10.74 GB of ~14.8 GB usable
#
# NOTE (2026-09-17): the coder subagent and /implement were removed - the 7b
# cannot call tools (tests/test-toolcalls.ps1: only the qwen3 family + devstral
# pass, and this profile keeps the 8b as a light main seat), so /implement
# silently did nothing. The 7b is kept resident
# only as a cheap model to ASK for code text; it cannot edit. The planner also
# moved off deepseek-r1 to qwen3:8b for the same reason, so /plan no longer
# swaps a 12 GB reasoner in and out.
#
# Workflow:
#   /plan <scope>   -> qwen3:8b writes/updates docs/implementation-tasks.md
#   then tell the main agent: "execute task #N from docs/implementation-tasks.md"
#
# Why qwen3 leads: only the qwen3 family (and devstral:24b) emits a parseable
# tool call on this stack. Probed 2026-09-17 via /api/chat with a tool schema
# (tests/test-toolcalls.ps1): qwen3:8b and qwen3:14b return populated
# tool_calls; every qwen2.5-coder size and every deepseek-r1 variant returns an
# EMPTY tool_calls array and prints the call as chat text instead. That is not
# a quality judgement - a model that fails the probe cannot edit a file at all,
# and will report success anyway.

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=false
export DEV_TIERS_DESKTOP=true
export DEV_TIERS_GO=false
export DEV_TIERS_NODE3=false

export DEV_DESKTOP_MODELS="qwen3:8b qwen2.5-coder:7b deepseek-r1:14b"

export OLLAMA_DESKTOP_URL="http://localhost:11434"
export OLLAMA_DESKTOP_BASE_URL="${OLLAMA_DESKTOP_BASE_URL:-http://localhost:11434/v1}"

export OPENCODE_MODEL="ollama-desktop/qwen3:8b"
export OPENCODE_SMALL_MODEL="ollama-desktop/qwen2.5-coder:7b"

echo "[profile] Workflow Resident: qwen3 orchestrates, coder + deepseek subagents"