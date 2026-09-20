#!/usr/bin/env bash
# dev-desktop-only.sh - Everything local on this PC (Vulkan). Use when the server is down.
# Use when the dev server is out of commission - no server, no cloud.
# Qwen 7b autocomplete + DeepSeek 14b reasoner (baked 16k) + Qwen3 8b general.

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=false
export DEV_TIERS_DESKTOP=true
export DEV_TIERS_GO=false
export DEV_TIERS_NODE3=false

# Models to have installed on the desktop (explicit tags - lean set, all fit)
export DEV_DESKTOP_MODELS="qwen2.5-coder:7b deepseek-r1:14b qwen3:8b"

# Running on the box itself - localhost, immune to LAN/IP changes
export OLLAMA_DESKTOP_URL="http://localhost:11434"
export OLLAMA_DESKTOP_BASE_URL="${OLLAMA_DESKTOP_BASE_URL:-http://localhost:11434/v1}"

# MAIN SEAT = qwen3:8b - only the qwen3 family (8b/14b) emits a parseable tool
# call (probe: tests/test-toolcalls.ps1). A qwen2.5-coder or deepseek-r1 tag
# here makes the agent chat-only: it describes edits it never made. Those tags
# stay installed and registered for deliberate no-tools use.
export OPENCODE_MODEL="ollama-desktop/qwen3:8b"
export OPENCODE_SMALL_MODEL="ollama-desktop/qwen2.5-coder:7b"

echo "[profile] Desktop only: Qwen 7b + DeepSeek 14b + Qwen3 8b, all on this PC"
