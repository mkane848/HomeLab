#!/usr/bin/env bash
# dev-node3.sh - Activate the third node as an Ollama node (RTX 3080 FE, 10GB)
# FUTURE/STUB: the node is NOT onboarded yet. Requires NODE3_IP in .env.
# When live, it hosts general + embed models; its 5950X is strong enough for
# good CPU offload of larger models too.
#
# Until NODE3_IP is set, this profile still works (server autocomplete only) but
# prints a warning and keeps the third-node tier off.

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=true
export DEV_TIERS_DESKTOP=false
export DEV_TIERS_GO=false

# Models to have installed on each host
export DEV_SERVER_MODELS="autocomplete"
export DEV_NODE3_MODELS="general embed"

export OLLAMA_SERVER_URL="http://localhost:11434"
export OLLAMA_SERVER_BASE_URL="${OLLAMA_SERVER_BASE_URL:-http://localhost:11434/v1}"

if [[ -n "${NODE3_IP:-}" ]]; then
    export DEV_TIERS_NODE3=true
    export OLLAMA_NODE3_URL="http://${NODE3_IP}:11434"
    export OLLAMA_NODE3_BASE_URL="http://${NODE3_IP}:11434/v1"
    export OPENCODE_MODEL="ollama-node3/qwen3:8b"
    export OPENCODE_SMALL_MODEL="ollama-server/qwen2.5-coder:7b"
    echo "[profile] Third node ACTIVE ($NODE3_IP): general + embed models"
else
    export DEV_TIERS_NODE3=false
# MAIN SEAT = qwen3:8b - the only model that emits a parseable tool call
# (probe: tests/test-toolcalls.ps1). A qwen2.5-coder or deepseek-r1 tag here
# makes the agent chat-only: it describes edits it never made. Those tags
# stay installed and registered for deliberate no-tools use.
    export OPENCODE_MODEL="ollama-server/qwen3:8b"
    export OPENCODE_SMALL_MODEL="ollama-server/qwen2.5-coder:7b"
    echo "[profile] WARNING: NODE3_IP not set in .env - third-node tier inactive (server autocomplete only)" >&2
    echo "[profile] Set NODE3_IP in .env and re-source to onboard the 3080 FE node." >&2
fi
