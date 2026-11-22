#!/usr/bin/env bash
# startup.sh - Start the server's model engine, llama.cpp (docker-compose.llamacpp.yml,
# restart: unless-stopped). Ollama was removed on 2026-11-21; llama.cpp is the only engine.
#
#   ./server/scripts/startup.sh
#
# The systemd unit (llamacpp-server.service, template in server/systemd/) is used when
# installed; otherwise docker compose directly. Exit 1 when the container is not healthy
# within the wait.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/../docker"
if [[ $# -gt 0 ]]; then echo "usage: startup.sh" >&2; exit 2; fi
COMPOSE="$DOCKER_DIR/docker-compose.llamacpp.yml"; SERVICE_NAME="llamacpp-server"; SYSTEMD_UNIT="llamacpp-server.service"; WAIT=300

# Check if server tier is enabled by profile
if [[ -n "${DEV_TIERS_SERVER:-}" && "$DEV_TIERS_SERVER" != "true" ]]; then
    echo "[startup] Server tier disabled by profile, skipping."
    exit 0
fi

echo "[startup] Starting the server's engine: llama.cpp"

if systemctl list-unit-files "$SYSTEMD_UNIT" 2>/dev/null | grep -q "^$SYSTEMD_UNIT"; then
    echo "[startup] Using systemd unit: $SYSTEMD_UNIT"
    sudo systemctl start "$SYSTEMD_UNIT"
    systemctl status "$SYSTEMD_UNIT" --no-pager || true
else
    echo "[startup] No $SYSTEMD_UNIT installed, using docker compose ($COMPOSE)..."
    docker compose -f "$COMPOSE" up -d
fi

echo "[startup] Waiting up to ${WAIT}s for $SERVICE_NAME to become healthy..."
for _ in $(seq 1 $(( WAIT / 2 ))); do
    if docker inspect --format='{{.State.Health.Status}}' "$SERVICE_NAME" 2>/dev/null | grep -qx "healthy"; then
        echo "[startup] $SERVICE_NAME is healthy."
        exit 0
    fi
    sleep 2
done

echo "[startup] Warning: $SERVICE_NAME started but its health check didn't pass in ${WAIT}s."
echo "[startup] Run 'docker logs $SERVICE_NAME' to check."
exit 1
