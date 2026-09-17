#!/usr/bin/env bash
# dev-go-only.sh - Local Qwen + OpenCode Go (cloud) subscription
# Use the cloud tier to test models you can't run yourself:
# DeepSeek V4, Qwen3.x, Kimi, GLM, and more (opencode-go/<model-id>).
# Good for evaluating a model before it's pulled locally (or at all).

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=true
export DEV_TIERS_DESKTOP=false
export DEV_TIERS_GO=true
export DEV_TIERS_NODE3=false

# Models to have installed on the server
export DEV_SERVER_MODELS="autocomplete"

export OLLAMA_SERVER_URL="http://localhost:11434"
export OLLAMA_SERVER_BASE_URL="${OLLAMA_SERVER_BASE_URL:-http://localhost:11434/v1}"

# Leave OPENCODE_MODEL unset -> OpenCode config default is the Go model.
echo "[profile] Go mode: Qwen + OpenCode Go models"