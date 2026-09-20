#!/usr/bin/env bash
# dev-server-all.sh - Everything on the server, desktop idle
# Qwen 7b autocomplete + Qwen 14b coder + DeepSeek 14b reasoner, all on the
# server. This is the point of the 4070 Ti Super: heavier loads the desktop
# (Vulkan, 16 GB) could not hold alongside day-to-day use, on one box.

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=true
export DEV_TIERS_DESKTOP=false
export DEV_TIERS_GO=false
export DEV_TIERS_NODE3=false

# Models to have installed on the server
export DEV_SERVER_MODELS="autocomplete coder reasoner"

export OLLAMA_SERVER_URL="http://localhost:11434"
export OLLAMA_SERVER_BASE_URL="${OLLAMA_SERVER_BASE_URL:-http://localhost:11434/v1}"

# MAIN SEAT = qwen3:8b - the only model that emits a parseable tool call
# (probe: tests/test-toolcalls.ps1). A qwen2.5-coder or deepseek-r1 tag here
# makes the agent chat-only: it describes edits it never made. Those tags
# stay installed and registered for deliberate no-tools use.
export OPENCODE_MODEL="ollama-server/qwen3:8b"
export OPENCODE_SMALL_MODEL="ollama-server/qwen2.5-coder:7b"

echo "[profile] Server-all: Qwen 7b autocomplete + 14b coder + DeepSeek 14b reasoner"
