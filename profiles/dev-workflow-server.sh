#!/usr/bin/env bash
# dev-workflow-server.sh - the quality loop, with the models on the server
#
# opencode runs on the DESKTOP (or anywhere on the LAN); the main seat runs on the
# server's RTX 4070 Ti SUPER (16GB, CUDA): ollama-server/qwen3.6:35b-a3b-coding,
# the same weights and the same 64k bake as dev-workflow-quality's desktop seat.
# The desktop tier is OFF: the desktop is the owner's planning and gaming machine,
# not the executor host (docs/roadmap.md -> "Next up", 2026-10-10: server first).
#
# Rewritten 2026-10-12 when the server came back on a replacement board. The
# previous version seated the pre-qwen3.6 setup (qwen3:8b + a desktop R1 planner);
# `/plan` runs on the main seat now, so nothing needs the desktop.
#
# What is measured, and what is not (docs/roadmap.md -> "Next up", step 3):
#   - tests/test-toolcalls.ps1 against this host on Ollama 0.34.3
#     (tests/results/toolcalls-summary.tsv, host "server"): the seat's probe.
#   - Co-residency: qwen3:8b @32k is 7.64 GB, all on the GPU, with the CPU-pinned
#     3b loaded beside it using 0 VRAM (/api/ps, 2026-10-12).
#   - qwen3.6's placement on 16 GB of CUDA + 32 GB of RAM, and its speed against
#     the desktop, are step 3's job. The 3700X is the fleet's weakest CPU and the
#     MoE's spill runs on it. Do not quote desktop numbers for this host.
#
# The small model is the 3b with num_gpu 0 (bake-models.sh derives it), for the
# reason in dev-workflow-quality.sh: a GPU companion evicts the main seat.
#
# Server setup (docs/network-topology.md -> "SSH access"):
#   ./server/scripts/install-model.sh qwen3.6:35b-a3b-coding qwen3:8b
#   docker exec ollama-server ollama pull qwen2.5-coder:3b    # not in the catalog
#   ./server/scripts/bake-models.sh                           # num_ctx + the CPU 3b
# Probe before trusting any seat here:
#   .\tests\test-toolcalls.ps1 -Model qwen3.6:35b-a3b-coding -OllamaHost http://SERVER_IP:11434 -HostLabel server

# Load shared vars from .env
DEVDOCS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[[ -f "$DEVDOCS_ENV" ]] && set -a && source "$DEVDOCS_ENV" && set +a

export DEV_TIERS_SERVER=true
export DEV_TIERS_DESKTOP=false
export DEV_TIERS_GO=false
export DEV_TIERS_NODE3=false

# qwen2.5-coder:3b is the base of the CPU companion (not in models/catalog.tsv, like
# the desktop's list); install-model.sh reports it as "nothing to install".
export DEV_SERVER_MODELS="qwen3.6:35b-a3b-coding qwen3:8b qwen2.5-coder:3b"

# This profile runs against the REMOTE server: default to SERVER_IP (from .env), NOT localhost.
export OLLAMA_SERVER_BASE_URL="${OLLAMA_SERVER_BASE_URL:-http://${SERVER_IP:-SERVER_IP}:11434/v1}"

# The desktop provider stays defined in the config; give it its usual default so the
# resolved config is valid even though nothing here uses it.
export OLLAMA_DESKTOP_URL="http://localhost:11434"
export OLLAMA_DESKTOP_BASE_URL="${OLLAMA_DESKTOP_BASE_URL:-http://localhost:11434/v1}"

# MAIN SEAT = qwen3.6 (a tool-capable seat; the probe above is the gate). A
# qwen2.5-coder or deepseek-r1 tag here makes the agent chat-only: it describes
# edits it never made. Those tags stay installed for deliberate no-tools use.
export OPENCODE_MODEL="ollama-server/qwen3.6:35b-a3b-coding"
export OPENCODE_SMALL_MODEL="ollama-server/qwen2.5-coder-3b-cpu"

# Don't let opencode auto-load ~/.claude/skills into every request (see
# dev-workflow-quality.sh). Keep it set.
export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1

echo "[profile] Workflow Server: qwen3.6 on the server (64k), CPU 3b companion, desktop idle"
