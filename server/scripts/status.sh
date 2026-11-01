#!/usr/bin/env bash
# status.sh — Check server-side service status: both engines. llama.cpp is the primary engine since Phase 3
# (2026-11-01); the Ollama container is stopped for the soak, so "Ollama: stopped" is expected, not a fault.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CATALOG="$PROJECT_ROOT/models/catalog.sh"

echo "=== Server Services Status ==="
echo ""

# Check systemd (either engine's unit, when installed)
for SYSTEMD_UNIT in llamacpp-server.service ollama-server.service; do
    if systemctl list-unit-files "$SYSTEMD_UNIT" 2>/dev/null | grep -q "^$SYSTEMD_UNIT"; then
        echo "--- Systemd Unit: $SYSTEMD_UNIT ---"
        systemctl status "$SYSTEMD_UNIT" --no-pager 2>/dev/null || true
        echo ""
    fi
done

# Check docker
echo "--- Docker Containers ---"
docker ps -a --filter "name=ollama-server" --filter "name=llamacpp-server" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "(docker not available)"
for c in llamacpp-server ollama-server; do
    printf '  %-16s restart=%s\n' "$c" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null || echo '?')"
done
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
# Ollama then runs on the CPU alone and still answers the API.
running="$(docker ps --format '{{.Names}}' 2>/dev/null)"
for c in llamacpp-server ollama-server; do
    grep -qx "$c" <<<"$running" || continue
    if docker exec "$c" nvidia-smi -L &>/dev/null; then
        echo "In $c: $(docker exec "$c" nvidia-smi -L | head -1)"
    else
        compose_file="docker-compose.yml"; [ "$c" = llamacpp-server ] && compose_file="docker-compose.llamacpp.yml"
        echo "In $c: GPU NOT VISIBLE (NVML failed) - it is running on the CPU only."
        echo "  Fix: docker compose -f server/docker/$compose_file up -d --force-recreate"
        echo "  See docs/troubleshooting.md -> 'Container lost the GPU'."
    fi
done
echo ""

# llama.cpp (the primary engine since Phase 3)
echo "--- llama.cpp (http://localhost:8090) ---"
if curl -sf http://localhost:8090/health &>/dev/null; then
    echo "llama-server: UP, build $(curl -sf http://localhost:8090/props | python3 -c "import sys,json; print(json.load(sys.stdin).get('build_info','?'))" 2>/dev/null || echo '?')"
    echo "Seats:"
    curl -sf http://localhost:8090/models | python3 -c "import sys,json; [print(f'  {m[\"id\"]:<28} {m.get(\"status\",{}).get(\"value\",\"?\")}') for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null || echo "  (could not read /models)"
else
    echo "llama-server: DOWN or not responding (start: ./server/scripts/startup.sh)"
fi
echo ""

# Check if Ollama API is responding
echo "--- Ollama API ---"
if curl -sf http://localhost:11434/api/tags &>/dev/null; then
    echo "Ollama API: UP (http://localhost:11434)"
    echo ""
    echo "Installed models:"
    curl -sf http://localhost:11434/api/tags | python3 -m json.tool 2>/dev/null || curl -sf http://localhost:11434/api/tags
    echo ""
    echo "Loaded models + context (VRAM check):"
    curl -sf http://localhost:11434/api/ps | python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'  {m[\"name\"]:<28} ctx={m.get(\"context_length\",\"?\")} total={m[\"size\"]/1e9:.2f}GB vram={m[\"size_vram\"]/1e9:.2f}GB ({100*m[\"size_vram\"]/max(m[\"size\"],1):.0f}% GPU)') for m in d.get(\"models\",[])]" 2>/dev/null || curl -sf http://localhost:11434/api/ps
else
    echo "Ollama API: not responding (expected since Phase 3: the container is stopped for the soak)"
fi

# Catalog availability (which catalog models are still missing)
if [[ -f "$CATALOG" ]]; then
    echo ""
    echo "--- Catalog Status (installed vs planned) ---"
    source "$CATALOG"
    installed=$(curl -sf http://localhost:11434/api/tags 2>/dev/null | python3 -c "import sys,json; [print(m['name']) for m in json.load(sys.stdin)['models']]" 2>/dev/null || true)
    if [[ -n "$installed" ]]; then
        for tag in $(awk -F '\t' 'NR>1 { print $1 }' "$(dirname "$CATALOG")/catalog.tsv"); do
            if echo "$installed" | grep -qxF "$tag"; then
                printf "  installed %-24s %s\n" "$tag" "OK"
            else
                printf "  missing   %-24s %s\n" "$tag" "(install-model.sh $tag)"
            fi
        done
    else
        echo "  (could not list installed models — is Ollama up?)"
    fi
fi