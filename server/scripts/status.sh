#!/usr/bin/env bash
# status.sh — Check server-side service status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CATALOG="$PROJECT_ROOT/models/catalog.sh"

echo "=== Server Services Status ==="
echo ""

# Check systemd
SYSTEMD_UNIT="ollama-server.service"
if systemctl list-unit-files "$SYSTEMD_UNIT" &>/dev/null; then
    echo "--- Systemd Unit ---"
    systemctl status "$SYSTEMD_UNIT" --no-pager 2>/dev/null || true
    echo ""
fi

# Check docker
echo "--- Docker Containers ---"
docker ps --filter "name=ollama" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "(docker not available)"
echo ""

# GPU status (NVIDIA)
echo "--- GPU ---"
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu --format=csv
else
    echo "(nvidia-smi not found — GPU passthrough likely broken)"
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
    curl -sf http://localhost:11434/api/ps | python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'  {m[\"name\"]:<28} ctx={m.get(\"context_length\",\"?\")}') for m in d.get(\"models\",[])]" 2>/dev/null || curl -sf http://localhost:11434/api/ps
else
    echo "Ollama API: DOWN or not responding"
fi

# Catalog availability (which catalog models are still missing)
if [[ -f "$CATALOG" ]]; then
    echo ""
    echo "--- Catalog Status (installed vs planned) ---"
    source "$CATALOG"
    installed=$(curl -sf http://localhost:11434/api/tags 2>/dev/null | python3 -c "import sys,json; [print(m['name']) for m in json.load(sys.stdin)['models']]" 2>/dev/null || true)
    if [[ -n "$installed" ]]; then
        for tag in $(awk -F '\t' 'NR>1 { print $1 }' "$(dirname "$CATALOG")/catalog.tsv"); do
            if echo "$installed" | grep -qF "$tag"; then
                printf "  installed %-24s %s\n" "$tag" "OK"
            else
                printf "  missing   %-24s %s\n" "$tag" "(install-model.sh $tag)"
            fi
        done
    else
        echo "  (could not list installed models — is Ollama up?)"
    fi
fi