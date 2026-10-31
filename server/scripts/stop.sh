#!/usr/bin/env bash
# stop.sh — Stop server-side services

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/../docker"

SYSTEMD_UNIT="ollama-server.service"

if systemctl list-unit-files "$SYSTEMD_UNIT" &>/dev/null; then
    echo "[stop] Stopping systemd unit: $SYSTEMD_UNIT"
    sudo systemctl stop "$SYSTEMD_UNIT"
else
    echo "[stop] Stopping docker compose services..."
    docker compose -f "$DOCKER_DIR/docker-compose.yml" down
fi

echo "[stop] Done."
