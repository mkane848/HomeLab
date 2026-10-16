#!/usr/bin/env bash
# dev-workflow-server-llamacpp.sh - dev-workflow-server with llama.cpp as the engine
#
# Twin of dev-workflow-server.sh (docs/roadmap.md -> "Replacing Ollama", Phase 2): the same
# seats on the same server, served by llama-server (router mode, port 8090) instead of
# Ollama. Only OPENCODE_MODEL / OPENCODE_SMALL_MODEL differ; the provider is
# `llamacpp-server`, whose model ids are the preset's section names
# (server/llamacpp/models.ini) and whose limit.context equals the preset's `c`.
#
# Needs the llama.cpp stack up on the server (server/docker/docker-compose.llamacpp.yml);
# it is its own compose project (docs/llamacpp-trial.md). The weights are Ollama's own blobs, so DEV_SERVER_MODELS below still names
# what must be pulled on the server (and bake-models.sh still bakes it). Launch:
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

# Mirrors models/server-seats.tsv. qwen2.5-coder:3b is the base of the CPU companion and
# is not in models/catalog.tsv (like the desktop's list), so install-model.sh --profile
# reports it as "nothing to install": bake-models.sh is what pulls it.
export DEV_SERVER_MODELS="qwen3.6:35b-a3b-coding qwen3:8b qwen2.5-coder:3b"

# The Ollama endpoint stays defined (the install checks and the Ollama provider read it).
# This profile runs against the REMOTE server: default to SERVER_IP (from .env), NOT localhost.
export OLLAMA_SERVER_BASE_URL="${OLLAMA_SERVER_BASE_URL:-http://${SERVER_IP:-SERVER_IP}:11434/v1}"

# The desktop provider stays defined in the config; give it its usual default so the
# resolved config is valid even though nothing here uses it.
export OLLAMA_DESKTOP_URL="http://localhost:11434"
export OLLAMA_DESKTOP_BASE_URL="${OLLAMA_DESKTOP_BASE_URL:-http://localhost:11434/v1}"

# llama.cpp providers (docs/roadmap.md -> "Replacing Ollama", Phase 2). {env:...} has
# no fallbacks, so every live profile exports the server's endpoint even if it seats
# nothing there. The desktop and node3 have no llama-server until Phases 4 and 5.
export LLAMACPP_SERVER_BASE_URL="${LLAMACPP_SERVER_BASE_URL:-http://${SERVER_IP:-SERVER_IP}:8090/v1}"
export LLAMACPP_SERVER_SSH="${LLAMACPP_SERVER_SSH:-server}"
export LLAMACPP_DESKTOP_BASE_URL="${LLAMACPP_DESKTOP_BASE_URL:-http://localhost:8090/v1}"

# MAIN SEAT = qwen3.6 (a tool-capable seat; the probe above is the gate). A
# qwen2.5-coder or deepseek-r1 tag here makes the agent chat-only: it describes
# edits it never made. Those tags stay installed for deliberate no-tools use.
export OPENCODE_MODEL="llamacpp-server/qwen3.6:35b-a3b-coding"
export OPENCODE_SMALL_MODEL="llamacpp-server/qwen2.5-coder-3b-cpu"

# Don't let opencode auto-load ~/.claude/skills into every request (see
# dev-workflow-quality.sh). Keep it set.
export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1

echo "[profile] Workflow Server (llama.cpp): qwen3.6 on the server (64k), CPU 3b companion, desktop idle"
