#!/usr/bin/env bash
# startup.sh - Start the server's model engine.
#
# Since Phase 3 of "Replacing Ollama" (2026-11-01, docs/roadmap.md) the engine is llama.cpp
# (docker-compose.llamacpp.yml, restart: unless-stopped); the Ollama stack is stopped, not removed, for the soak.
#
#   ./server/scripts/startup.sh                    # llama.cpp (the default)
#   ./server/scripts/startup.sh --engine ollama    # roll back to Ollama (stop the llama.cpp stack first: the card
#                                                  # cannot hold both engines' seats)
#   SERVER_ENGINE=ollama ./server/scripts/startup.sh
#
# A systemd unit for the engine (llamacpp-server.service / ollama-server.service, templates in server/systemd/) is
# used when installed; otherwise docker compose directly. Exit 1 when the container is not healthy within the wait.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/../docker"
ENGINE="${SERVER_ENGINE:-llamacpp}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine) ENGINE="${2:-}"; shift 2 ;;
        *) echo "usage: startup.sh [--engine llamacpp|ollama]" >&2; exit 2 ;;
    esac
done
case "$ENGINE" in
    llamacpp) COMPOSE="$DOCKER_DIR/docker-compose.llamacpp.yml"; SERVICE_NAME="llamacpp-server"; SYSTEMD_UNIT="llamacpp-server.service"; WAIT=300 ;;
    ollama)   COMPOSE="$DOCKER_DIR/docker-compose.yml";          SERVICE_NAME="ollama-server";   SYSTEMD_UNIT="ollama-server.service";   WAIT=60 ;;
    *) echo "[startup] unknown engine '$ENGINE' (llamacpp or ollama)" >&2; exit 2 ;;
esac

# Check if server tier is enabled by profile
if [[ -n "${DEV_TIERS_SERVER:-}" && "$DEV_TIERS_SERVER" != "true" ]]; then
    echo "[startup] Server tier disabled by profile, skipping."
    exit 0
fi

echo "[startup] Starting the server's engine: $ENGINE"

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
