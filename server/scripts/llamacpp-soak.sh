#!/usr/bin/env bash
# llamacpp-soak.sh - the llama.cpp trial's E3 soak (docs/llamacpp-trial.md, step 8).
#
# Every INTERVAL seconds, for HOURS hours: unload whatever is loaded, load the next
# seat (qwen3:8b and qwen3.6:35b-a3b-coding alternately), wait until the router says
# `loaded` or `failed`, send it one short request, and log one TSV row with host RAM,
# VRAM, the container's health and restart count. Any growth, crash or hang counts.
#
# Two router-mode facts from the trial (2026-10-13, build b11561) shape it:
#  * router mode counts models, not VRAM: it will not evict qwen3.6 to make room for
#    qwen3:8b, the second load fails on a CUDA allocation. So every cycle unloads
#    first.
#  * POST /models/load answers {"success":true} before the load has happened, so the
#    outcome is read from GET /models (status "loaded", or "failed").
#
# Run it on the server, detached, so the desktop session can end:
#   nohup bash server/scripts/llamacpp-soak.sh > ~/llamacpp-soak.out 2>&1 &
# Read it afterwards: ~/llamacpp-soak.tsv (one row per cycle); `ok` is 1 when the
# load and the request both succeeded. Grep for ok=0, a rising restarts column, an
# unhealthy health column, or a VRAM/RAM trend at the same seat.
# Env overrides: URL (http://localhost:8090), HOURS (24), INTERVAL (600),
# LOG (~/llamacpp-soak.tsv), CONTAINER (llamacpp-server).
set -uo pipefail

URL="${URL:-http://localhost:8090}"
HOURS="${HOURS:-24}"
INTERVAL="${INTERVAL:-600}"
LOG="${LOG:-$HOME/llamacpp-soak.tsv}"
CONTAINER="${CONTAINER:-llamacpp-server}"
SEATS=("qwen3:8b" "qwen3.6:35b-a3b-coding")

# Router status of one seat, by tag or alias: loaded | loading | unloaded | failed | missing.
status_of() {
    curl -s --max-time 10 "$URL/models" | python3 -c '
import json, sys
tag = sys.argv[1]
try:
    data = json.load(sys.stdin).get("data", [])
except Exception:
    print("noanswer"); sys.exit()
for m in data:
    if m.get("id") == tag or tag in (m.get("aliases") or []):
        st = m.get("status") or {}
        print("failed" if st.get("failed") else st.get("value", "unknown")); break
else:
    print("missing")' "$1"
}

if [ ! -f "$LOG" ]; then
    printf 'time\tcycle\tseat\tload\tloadS\trequest\trequestS\tok\tvramUsedMiB\tramUsedMiB\tramAvailMiB\thealth\trestarts\n' > "$LOG"
fi

end=$(( $(date +%s) + HOURS * 3600 ))
cycle=0
while [ "$(date +%s)" -lt "$end" ]; do
    start=$(date +%s)
    seat="${SEATS[$(( cycle % 2 ))]}"

    for s in "${SEATS[@]}"; do
        curl -s --max-time 60 -X POST "$URL/models/unload" -H 'Content-Type: application/json' \
            -d "{\"model\":\"$s\"}" > /dev/null || true
    done
    sleep 5

    t0=$(date +%s.%N)
    curl -s --max-time 60 -X POST "$URL/models/load" -H 'Content-Type: application/json' \
        -d "{\"model\":\"$seat\"}" > /dev/null || true
    load="timeout"
    for _ in $(seq 1 120); do              # up to 6 minutes
        st=$(status_of "$seat")
        if [ "$st" = "loaded" ] || [ "$st" = "failed" ]; then load="$st"; break; fi
        sleep 3
    done
    loadS=$(python3 -c "import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 1))" "$t0" "$(date +%s.%N)")

    request="skipped"; requestS=""
    if [ "$load" = "loaded" ]; then
        t1=$(date +%s.%N)
        code=$(curl -s --max-time 300 -o /tmp/llamacpp-soak-reply.json -w '%{http_code}' \
            "$URL/v1/chat/completions" -H 'Content-Type: application/json' \
            -d "{\"model\":\"$seat\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":400}")
        requestS=$(python3 -c "import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 1))" "$t1" "$(date +%s.%N)")
        if [ "$code" = "200" ] && grep -q '"choices"' /tmp/llamacpp-soak-reply.json; then request="200"; else request="${code:-000}"; fi
    fi
    ok=0; [ "$load" = "loaded" ] && [ "$request" = "200" ] && ok=1

    vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    read -r ramUsed ramAvail < <(free -m | awk '/^Mem:/{print $3, $7}')
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo gone)
    restarts=$(docker inspect --format '{{.RestartCount}}' "$CONTAINER" 2>/dev/null || echo -)

    printf '%s\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -Is)" "$cycle" "$seat" "$load" "$loadS" "$request" "$requestS" "$ok" \
        "${vram:-}" "$ramUsed" "$ramAvail" "$health" "$restarts" >> "$LOG"

    cycle=$(( cycle + 1 ))
    rest=$(( INTERVAL - ($(date +%s) - start) ))
    [ "$rest" -gt 0 ] && sleep "$rest"
done
echo "soak done $(date -Is): $cycle cycles, log $LOG"
