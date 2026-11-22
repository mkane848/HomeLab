#!/usr/bin/env bash
# dev-workflow-server-llamacpp.sh - the default profile: qwen3.6 on the server's llama-server
#
# The main seat and its CPU companion on the server, served by llama-server (router mode,
# port 8090). The provider is `llamacpp-server`, whose model ids are the preset's section
# names (server/llamacpp/models.ini) and whose limit.context equals the preset's `c`.
# Began as the Ollama profile's twin (docs/roadmap.md -> "Replacing Ollama", Phase 2);
# Ollama was removed 2026-11-21 and the desktop runs no models.
#
# Needs the llama.cpp stack up on the server (server/docker/docker-compose.llamacpp.yml).
# The weights are GGUF files in the server's ~/models, pinned in models/server-seats.tsv.
# Launch:
#   opencode server-llamacpp          # PowerShell; desktop\scripts\opencode-profiles.ps1
# Text only: the vision projector is not loaded (docs/llamacpp-trial.md).
#
# Probe before trusting the seat on this engine:
#   .\tests\test-toolcalls.ps1 -Engine llamacpp -EngineHost http://SERVER_IP:8090 -Model qwen3.6:35b-a3b-coding

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=true
export DEV_TIERS_DESKTOP=false
export DEV_TIERS_GO=false
export DEV_TIERS_NODE3=false

# llama.cpp providers. {env:...} has no fallbacks, so every live profile exports every
# provider's endpoint the config names, even one it seats nothing on.
export LLAMACPP_SERVER_BASE_URL="${LLAMACPP_SERVER_BASE_URL:-http://${SERVER_IP:-SERVER_IP}:8090/v1}"
export LLAMACPP_SERVER_SSH="${LLAMACPP_SERVER_SSH:-server}"
export LLAMACPP_NODE3_BASE_URL="${LLAMACPP_NODE3_BASE_URL:-http://${NODE3_IP:-NODE3_IP}:8090/v1}"

# MAIN SEAT = qwen3.6 (a tool-capable seat; the probe above is the gate). A tag that
# fails the probe makes the agent chat-only: it describes edits it never made.
export OPENCODE_MODEL="llamacpp-server/qwen3.6:35b-a3b-coding"
export OPENCODE_SMALL_MODEL="llamacpp-server/qwen2.5-coder-3b-cpu"

# Don't let opencode auto-load ~/.claude/skills into every request (~1.5k standing
# tokens of the preamble; measured 16851 total vs the ~11.4k baseline). Keep it set.
export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1

echo "[profile] Workflow Server (llama.cpp): qwen3.6 on the server (64k), CPU 3b companion, desktop idle"
