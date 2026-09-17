#!/usr/bin/env bash
# dev-workflow-server.sh - "Server-powered coder" (for when the dev server is back)
#
# opencode runs on the DESKTOP, but the heavy coder runs on the server's
# 4070 Ti Super (16GB): ollama-server/qwen2.5-coder:14b. The desktop keeps its
# local R1 for /plan planning and the 7b for autocomplete.
#
# No VRAM contention anywhere:
#   server  : qwen2.5-coder:14b - native 16k ctx via OLLAMA_CONTEXT_LENGTH
#   desktop : deepseek-r1-16k planner + qwen2.5-coder:7b autocomplete
#
# Workflow is identical to dev-workflow-quality.sh (coder drives in-thread,
# deepseek /plan is a single-shot doc write). The 4070 Ti Super makes the 14b
# feel as fast as the 7b does locally.
#
# Server setup on first use: install server-side models via
# DESKTOP:  .\desktop\scripts\models.ps1 -Profile   (needs DEV_SERVER_MODELS UNLESS on server)
# SERVER:  ./server/scripts/install-model.sh qwen2.5-coder:14b (or -Profile)

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=true
# Desktop tier stays ON - the desktop still runs local ollama so the planner
# subagent (/plan) and autocomplete don't depend on the LAN.
export DEV_TIERS_DESKTOP=true
export DEV_TIERS_GO=false
export DEV_TIERS_NODE3=false

# Explicit tags (avoids the catalog "coder" group pulling codestral too)
export DEV_SERVER_MODELS="qwen2.5-coder:14b deepseek-r1:14b qwen3:8b"
export DEV_DESKTOP_MODELS="deepseek-r1:14b qwen2.5-coder:7b"

export OLLAMA_DESKTOP_URL="http://localhost:11434"
export OLLAMA_DESKTOP_BASE_URL="${OLLAMA_DESKTOP_BASE_URL:-http://localhost:11434/v1}"

# Server provider URL - this profile runs on the DESKTOP against the remote
# server, so default to SERVER_IP (from .env), NOT localhost.
export OLLAMA_SERVER_BASE_URL="${OLLAMA_SERVER_BASE_URL:-http://${SERVER_IP:-SERVER_IP}:11434/v1}"

# Main model from the server, autocomplete from the server too
# MAIN SEAT = qwen3:8b - the only model that emits a parseable tool call
# (probe: tests/test-toolcalls.ps1). A qwen2.5-coder or deepseek-r1 tag here
# makes the agent chat-only: it describes edits it never made. Those tags
# stay installed and registered for deliberate no-tools use.
export OPENCODE_MODEL="ollama-server/qwen3:8b"
export OPENCODE_SMALL_MODEL="ollama-server/qwen2.5-coder:7b"

echo "[profile] Workflow Server: server coder 14b, desktop R1 planner"
