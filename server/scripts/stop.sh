#!/usr/bin/env bash
# stop.sh - Stop the server's model engine, llama.cpp (see startup.sh). Ollama was removed on 2026-11-21.
#
#   ./server/scripts/stop.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/../docker"
if [[ $# -gt 0 ]]; then echo "usage: stop.sh" >&2; exit 2; fi
COMPOSE="$DOCKER_DIR/docker-compose.llamacpp.yml"; SYSTEMD_UNIT="llamacpp-server.service"

if systemctl list-unit-files "$SYSTEMD_UNIT" 2>/dev/null | grep -q "^$SYSTEMD_UNIT"; then
    echo "[stop] Stopping systemd unit: $SYSTEMD_UNIT"
    sudo systemctl stop "$SYSTEMD_UNIT"
else
    echo "[stop] Stopping docker compose services ($COMPOSE)..."
    docker compose -f "$COMPOSE" down
fi

echo "[stop] Done."
