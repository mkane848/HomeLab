#!/usr/bin/env bash
# dev-local-only.sh - Full local stack, no API costs
# Qwen 7b autocomplete (server) + DeepSeek 14b reasoner (desktop, native Vulkan).

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=true
export DEV_TIERS_DESKTOP=true
export DEV_TIERS_GO=false
export DEV_TIERS_NODE3=false

# Models to have installed on each host
export DEV_SERVER_MODELS="autocomplete"
export DEV_DESKTOP_MODELS="reasoner"

export OLLAMA_SERVER_URL="http://localhost:11434"
export OLLAMA_SERVER_BASE_URL="${OLLAMA_SERVER_BASE_URL:-http://localhost:11434/v1}"
export OLLAMA_DESKTOP_URL="http://${DESKTOP_IP}:11434"
export OLLAMA_DESKTOP_BASE_URL="http://${DESKTOP_IP}:11434/v1"

# Desktop DeepSeek (16k ctx - the baked model from startup.ps1)
# MAIN SEAT = qwen3:8b - the only model that emits a parseable tool call
# (probe: tests/test-toolcalls.ps1). A qwen2.5-coder or deepseek-r1 tag here
# makes the agent chat-only: it describes edits it never made. Those tags
# stay installed and registered for deliberate no-tools use.
export OPENCODE_MODEL="ollama-desktop/qwen3:8b"
export OPENCODE_SMALL_MODEL="ollama-server/qwen2.5-coder:7b"

echo "[profile] Local only: Qwen (server) + DeepSeek (desktop), zero cloud spend"
