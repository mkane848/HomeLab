#!/usr/bin/env bash
# dev-full.sh - All tiers online
# Server (coder + reasoner + general + creative + embed) + desktop (reasoner) +
# OpenCode Go (cloud for testing anything you can't run yourself).

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=true
export DEV_TIERS_DESKTOP=true
export DEV_TIERS_GO=true
export DEV_TIERS_NODE3=false

# Models to have installed on each host
export DEV_SERVER_MODELS="coder reasoner general creative embed"
export DEV_DESKTOP_MODELS="reasoner"

export OLLAMA_SERVER_URL="http://localhost:11434"
export OLLAMA_SERVER_BASE_URL="${OLLAMA_SERVER_BASE_URL:-http://localhost:11434/v1}"
export OLLAMA_DESKTOP_URL="http://${DESKTOP_IP}:11434"
export OLLAMA_DESKTOP_BASE_URL="http://${DESKTOP_IP}:11434/v1"

# Leave OPENCODE_MODEL unset -> OpenCode config default is the Go model,
# keeping the cloud tier as the default for testing new models.
echo "[profile] Full stack: server + desktop + OpenCode Go"