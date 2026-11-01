#!/usr/bin/env bash
# stop.sh - Stop the server's model engine (llama.cpp by default since Phase 3, 2026-11-01; see startup.sh).
#
#   ./server/scripts/stop.sh [--engine llamacpp|ollama]     (or SERVER_ENGINE=...)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/../docker"
ENGINE="${SERVER_ENGINE:-llamacpp}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine) ENGINE="${2:-}"; shift 2 ;;
        *) echo "usage: stop.sh [--engine llamacpp|ollama]" >&2; exit 2 ;;
    esac
done
case "$ENGINE" in
    llamacpp) COMPOSE="$DOCKER_DIR/docker-compose.llamacpp.yml"; SYSTEMD_UNIT="llamacpp-server.service" ;;
    ollama)   COMPOSE="$DOCKER_DIR/docker-compose.yml";          SYSTEMD_UNIT="ollama-server.service" ;;
    *) echo "[stop] unknown engine '$ENGINE' (llamacpp or ollama)" >&2; exit 2 ;;
esac

if systemctl list-unit-files "$SYSTEMD_UNIT" 2>/dev/null | grep -q "^$SYSTEMD_UNIT"; then
    echo "[stop] Stopping systemd unit: $SYSTEMD_UNIT"
    sudo systemctl stop "$SYSTEMD_UNIT"
else
    echo "[stop] Stopping docker compose services ($COMPOSE)..."
    docker compose -f "$COMPOSE" down
fi

echo "[stop] Done."
