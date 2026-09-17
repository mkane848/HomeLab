#!/usr/bin/env bash
# startup.sh — Bring server-side services online
# Auto-detects systemd unit vs docker compose

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_DIR="$SCRIPT_DIR/../docker"

SYSTEMD_UNIT="ollama-server.service"
SERVICE_NAME="ollama-server"

# Load profile if available
if [[ -n "${DEV_TIERS_SERVER:-}" && "$DEV_TIERS_SERVER" != "true" ]]; then
    echo "[startup] Server tier disabled by profile, skipping."
    exit 0
fi

echo "[startup] Starting server services..."

# Method 1: systemd (if unit is installed)
if systemctl list-unit-files "$SYSTEMD_UNIT" &>/dev/null; then
    echo "[startup] Using systemd unit: $SYSTEMD_UNIT"
    sudo systemctl start "$SYSTEMD_UNIT"
    echo "[startup] Started. Checking status..."
    systemctl status "$SYSTEMD_UNIT" --no-pager
    exit 0
fi

# Method 2: docker compose
echo "[startup] Systemd unit not found, using docker compose..."
if [[ -f "$DOCKER_DIR/.env" ]]; then
    export $(grep -v '^#' "$DOCKER_DIR/.env" | xargs)
fi

docker compose -f "$DOCKER_DIR/docker-compose.yml" up -d

echo "[startup] Waiting for container to become healthy..."
for i in $(seq 1 30); do
    if docker inspect --format='{{.State.Health.Status}}' "$SERVICE_NAME" 2>/dev/null | grep -q "healthy"; then
        echo "[startup] $SERVICE_NAME is healthy."
        exit 0
    fi
    sleep 2
done

echo "[startup] Warning: Container started but health check didn't pass in 60s."
echo "[startup] Run 'docker logs $SERVICE_NAME' to check."
