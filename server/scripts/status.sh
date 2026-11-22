#!/usr/bin/env bash
# status.sh — Check server-side service status: the llama.cpp engine (the only engine since
# Ollama was removed on 2026-11-21), its container, the GPU as the container sees it, and the seats.

set -euo pipefail

# API key (docs/engine-api-keys.md): llamacpp_curl adds it; /health is the only path that does not need it.
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/llamacpp-auth.sh"

echo "=== Server Services Status ==="
echo ""

SYSTEMD_UNIT=llamacpp-server.service
if systemctl list-unit-files "$SYSTEMD_UNIT" 2>/dev/null | grep -q "^$SYSTEMD_UNIT"; then
    echo "--- Systemd Unit: $SYSTEMD_UNIT ---"
    systemctl status "$SYSTEMD_UNIT" --no-pager 2>/dev/null || true
    echo ""
fi

# Check docker
echo "--- Docker Container ---"
docker ps -a --filter "name=llamacpp-server" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "(docker not available)"
printf '  %-16s restart=%s\n' llamacpp-server "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' llamacpp-server 2>/dev/null || echo '?')"
echo ""

# GPU status (NVIDIA)
echo "--- GPU ---"
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu --format=csv
else
    echo "(nvidia-smi not found — GPU passthrough likely broken)"
fi
# The GPU as the CONTAINER sees it. The host's nvidia-smi can be fine while the
# container has lost the device (a systemd reload resets its device-access rules):
# the engine then runs on the CPU alone and still answers the API.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx llamacpp-server; then
    if docker exec llamacpp-server nvidia-smi -L &>/dev/null; then
        echo "In llamacpp-server: $(docker exec llamacpp-server nvidia-smi -L | head -1)"
    else
        echo "In llamacpp-server: GPU NOT VISIBLE (NVML failed) - it is running on the CPU only."
        echo "  Fix: docker compose -f server/docker/docker-compose.llamacpp.yml up -d --force-recreate"
        echo "  See docs/troubleshooting.md -> 'Container lost the GPU'."
    fi
fi
echo ""

echo "--- llama.cpp (http://localhost:8090) ---"
if curl -sf http://localhost:8090/health &>/dev/null; then
    echo "llama-server: UP, build $(llamacpp_curl -sf http://localhost:8090/props | python3 -c "import sys,json; print(json.load(sys.stdin).get('build_info','?'))" 2>/dev/null || echo '?')"
    echo "Seats:"
    llamacpp_curl -sf http://localhost:8090/models | python3 -c "import sys,json; [print(f'  {m[\"id\"]:<28} {m.get(\"status\",{}).get(\"value\",\"?\")}') for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null || echo "  (could not read /models)"
else
    echo "llama-server: DOWN or not responding (start: ./server/scripts/startup.sh)"
fi
