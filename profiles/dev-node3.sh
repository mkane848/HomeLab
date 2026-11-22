#!/usr/bin/env bash
# dev-node3.sh - qwen3:8b on node3's llama-server (RTX 3080 FE, 10GB)
#
# Onboarded 2026-09-20 as an Ollama node; its llama-server (node3/llamacpp/models.ini)
# replaced Ollama on 2026-11-21. qwen3:8b is its agent seat. node3's llama-server binds
# 127.0.0.1 until its LAN firewall rule (node3/README.md), so from another machine set
# LLAMACPP_NODE3_BASE_URL to an address that reaches it (or run this on node3 with
# LLAMACPP_NODE3_BASE_URL=http://127.0.0.1:8090/v1).
#
# Requires NODE3_IP in .env (or LLAMACPP_NODE3_BASE_URL). Without either, the profile
# falls back to the server's qwen3:8b seat and prints a warning.

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=true
export DEV_TIERS_DESKTOP=false
export DEV_TIERS_GO=false

# llama.cpp providers. {env:...} has no fallbacks, so every live profile exports every
# provider's endpoint the config names.
export LLAMACPP_SERVER_BASE_URL="${LLAMACPP_SERVER_BASE_URL:-http://${SERVER_IP:-SERVER_IP}:8090/v1}"
export LLAMACPP_SERVER_SSH="${LLAMACPP_SERVER_SSH:-server}"

# Don't let opencode auto-load ~/.claude/skills into every request (~1.5k standing
# tokens of the preamble). Lean global scope; projects opt in via skills.paths.
export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1

# The small model (titles) is the server's CPU seat: it never competes with node3's GPU.
export OPENCODE_SMALL_MODEL="llamacpp-server/qwen2.5-coder-3b-cpu"

if [[ -n "${LLAMACPP_NODE3_BASE_URL:-}" || -n "${NODE3_IP:-}" ]]; then
    export DEV_TIERS_NODE3=true
    export LLAMACPP_NODE3_BASE_URL="${LLAMACPP_NODE3_BASE_URL:-http://${NODE3_IP}:8090/v1}"
    # MAIN SEAT = qwen3:8b, the tool-capable seat on this host (probe:
    # tests/test-toolcalls.ps1 -Engine llamacpp).
    export OPENCODE_MODEL="llamacpp-node3/qwen3:8b"
    echo "[profile] node3 ACTIVE ($LLAMACPP_NODE3_BASE_URL): qwen3:8b"
else
    export DEV_TIERS_NODE3=false
    export LLAMACPP_NODE3_BASE_URL="http://NODE3_IP:8090/v1"
    export OPENCODE_MODEL="llamacpp-server/qwen3:8b"
    echo "[profile] WARNING: neither NODE3_IP nor LLAMACPP_NODE3_BASE_URL is set - using the server's qwen3:8b" >&2
fi
