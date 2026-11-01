#!/usr/bin/env bash
# llamacpp-window.sh - open, watch and close an unattended llama.cpp window on the server.
#
# Why this exists: a testing window on the server's llama.cpp (docs/llamacpp-trial.md, steps 0 and 2) was opened
# and watched by hand. During the trial the container ran with `restart: "no"` (it must never fight Ollama for the
# GPU at boot), so a crash at 3 a.m. ended the night, and a window left open held the GPU into the morning. This is
# the same procedure with a clock on it: a deadline after which the stack is taken down whatever else happens,
# and a watchdog that restarts a dead or unhealthy llama-server a few times an hour while the window is open.
#
# Since Phase 3 (2026-11-01) llama.cpp is the server's primary engine (`restart: unless-stopped`, Ollama's container
# stopped), so the stack is usually up already. `up` then ADOPTS it: no Ollama stop, no GPU check, no start; it still
# loads the seat, runs the contract check, sets the deadline and starts the watchdog, and it writes
# $WINDOW_DIR/adopted. A window that adopted the stack leaves it running when it closes (deadline, STOP, give-up,
# `down`): the primary engine is not the window's to take away.
# docs/unattended-window.md is the runbook; tests/run-window.ps1 is the client that uses the window.
#
#   bash server/scripts/llamacpp-window.sh up [--hours 9] [--no-watch]   open (hours = the deadline, default 9)
#   bash server/scripts/llamacpp-window.sh status                         exit 0 only if open, healthy, seat loaded
#   bash server/scripts/llamacpp-window.sh down                           close now (stops the watchdog first)
#
# `up`: stops whatever Ollama has resident (the card cannot hold both engines' copies), waits for the GPU to be
# free, starts docker-compose.llamacpp.yml, waits for the container to be healthy (its healthcheck runs
# nvidia-smi inside the container), loads the seat and waits until the router says `loaded` (POST /models/load
# answers before the load has happened, so the outcome is read from GET /models, as llamacpp-soak.sh does), runs
# llamacpp-check.sh --url, then starts the watchdog in the background and returns. Any step that fails brings the
# stack down again and exits non-zero, so a failed `up` leaves Ollama free to serve in the morning.
#
# The watchdog polls every WATCH_INTERVAL seconds. Two bad polls in a row (container not running, `unhealthy`, or
# /health not answering) restart llama-server and load the seat again; the fifth restart within an hour gives up,
# writes GAVE-UP, and takes the stack down. The deadline, or a STOP file, takes it down too. Everything is logged
# to $WINDOW_DIR/window.log (events) and $WINDOW_DIR/watch.out (the watchdog's output).
#
# Exit codes: 0 ok; 1 status says not ready; 2 usage or a missing tool; 3 a window is already open; 4 the GPU is
# still held by something else; 5 llama-server did not come up healthy; 6 the seat did not load; 7 llamacpp-check
# failed.
#
# Env overrides: URL (http://localhost:8090), SEAT (qwen3.6:35b-a3b-coding), CONTAINER (llamacpp-server),
# OLLAMA_CONTAINER (ollama-server), WINDOW_DIR (~/llamacpp-window), WATCH_INTERVAL (30), MAX_USED_MIB (2500: the
# GPU memory still in use that blocks the start), MAX_RESTARTS (4 an hour), POLL (3: seconds between polls while
# waiting), HEALTH_WAIT (300), LOAD_WAIT (600), GPU_WAIT (90). DOCKER, CURL, NVIDIA_SMI and PYTHON name the
# binaries (tests/test-llamacpp-window.ps1 points them at stand-ins).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
self="$here/$(basename "${BASH_SOURCE[0]}")"
repo="$(cd "$here/../.." && pwd)"
compose="${COMPOSE_FILE:-$repo/server/docker/docker-compose.llamacpp.yml}"

URL="${URL:-http://localhost:8090}"
SEAT="${SEAT:-qwen3.6:35b-a3b-coding}"
CONTAINER="${CONTAINER:-llamacpp-server}"
OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-ollama-server}"
WINDOW_DIR="${WINDOW_DIR:-$HOME/llamacpp-window}"
WATCH_INTERVAL="${WATCH_INTERVAL:-30}"
MAX_USED_MIB="${MAX_USED_MIB:-2500}"
MAX_RESTARTS="${MAX_RESTARTS:-4}"
POLL="${POLL:-3}"
HEALTH_WAIT="${HEALTH_WAIT:-300}"
LOAD_WAIT="${LOAD_WAIT:-600}"
GPU_WAIT="${GPU_WAIT:-90}"
DOCKER="${DOCKER:-docker}"
CURL="${CURL:-curl}"
NVIDIA_SMI="${NVIDIA_SMI:-nvidia-smi}"
PYTHON="${PYTHON:-}"

log() {
    mkdir -p "$WINDOW_DIR"
    printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$WINDOW_DIR/window.log"
}
die() { local code="$1"; shift; echo "[llamacpp-window] $*" >&2; exit "$code"; }
dc() { "$DOCKER" compose -f "$compose" "$@"; }

# python3 if it runs, else python ("runs" matters on Windows, where python3 can be a Store placeholder).
find_python() {
    [ -n "$PYTHON" ] && return 0
    local cand
    for cand in python3 python; do
        if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then PYTHON="$cand"; return 0; fi
    done
    return 1
}

# Router status of the seat, by tag or alias: loaded | loading | unloaded | failed | missing | noanswer.
seat_status() {
    "$CURL" -s --max-time 10 "$URL/models" | "$PYTHON" -c '
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
    print("missing")' "$SEAT"
}

# "running healthy" | "running starting" | "exited none" | "gone"
container_state() {
    "$DOCKER" inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo gone
}

# 0 when the container runs, is not unhealthy, and /health answers.
server_ok() {
    local st; st="$(container_state)"
    case "$st" in "running healthy"|"running starting"|"running none") ;; *) return 1 ;; esac
    "$CURL" -fsS --max-time 10 "$URL/health" >/dev/null 2>&1
}

wait_healthy() {
    local start; start="$(date +%s)"
    while [ $(( $(date +%s) - start )) -lt "$HEALTH_WAIT" ]; do
        if [ "$(container_state)" = "running healthy" ]; then return 0; fi
        sleep "$POLL"
    done
    return 1
}

# Ask for the seat and wait until the router says loaded. 0 loaded, 1 failed or timed out.
load_seat() {
    local start st=""
    start="$(date +%s)"
    "$CURL" -s --max-time 60 -X POST "$URL/models/load" -H 'Content-Type: application/json' \
        -d "{\"model\":\"$SEAT\"}" >/dev/null || true
    while [ $(( $(date +%s) - start )) -lt "$LOAD_WAIT" ]; do
        st="$(seat_status)"
        case "$st" in
            loaded) return 0 ;;
            failed|missing) log "seat $SEAT: router says $st"; return 1 ;;
        esac
        sleep "$POLL"
    done
    log "seat $SEAT: not loaded after ${LOAD_WAIT}s (last status ${st:-?})"
    return 1
}

gpu_used_mib() {
    "$NVIDIA_SMI" --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' \r'
}

close_stack() {
    if [ -e "$WINDOW_DIR/adopted" ]; then
        log "leaving the stack up: it was running before the window opened (the primary engine since Phase 3)"
        rm -f "$WINDOW_DIR/adopted"
        return 0
    fi
    log "taking the stack down"
    dc down >>"$WINDOW_DIR/window.log" 2>&1 || log "docker compose down returned non-zero"
}

# Is $1 a live watchdog of this script (and not some process that reused the pid)?
is_watcher() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q 'llamacpp-window.sh.* watch' || return 1
    fi
    return 0
}

stop_watcher() {
    local pid
    if [ -f "$WINDOW_DIR/watch.pid" ]; then
        pid="$(cat "$WINDOW_DIR/watch.pid" 2>/dev/null)"
        if [ -n "$pid" ] && [ "$pid" != "$$" ] && is_watcher "$pid"; then kill "$pid" 2>/dev/null || true; fi
        rm -f "$WINDOW_DIR/watch.pid"
    fi
}

# Set while `up` is between starting the stack and handing it to the watchdog: an interrupt (Ctrl-C, ssh dropping,
# kill) in that stretch would leave the GPU held with no deadline, so it takes the stack down first.
UP_IN_PROGRESS=0
on_interrupt() {
    if [ "$UP_IN_PROGRESS" = 1 ]; then log "interrupted while opening the window: taking the stack down"; close_stack; fi
    exit 130
}

cmd_up() {
    local hours=9 watch=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --hours) hours="${2:?--hours needs a number}"; shift 2 ;;
            --no-watch) watch=0; shift ;;
            *) die 2 "unknown option for up: $1" ;;
        esac
    done
    command -v "$DOCKER" >/dev/null 2>&1 || die 2 "docker is not installed (or DOCKER does not name it)"
    command -v "$CURL" >/dev/null 2>&1 || die 2 "curl is not installed"
    find_python || die 2 "a working python3 (or python) is required"
    [ -f "$compose" ] || die 2 "no compose file at $compose"
    mkdir -p "$WINDOW_DIR"

    if [ -f "$WINDOW_DIR/watch.pid" ] && is_watcher "$(cat "$WINDOW_DIR/watch.pid" 2>/dev/null)"; then
        die 3 "a window is already open (watchdog pid $(cat "$WINDOW_DIR/watch.pid")); run 'down' first"
    fi
    rm -f "$WINDOW_DIR/STOP" "$WINDOW_DIR/GAVE-UP" "$WINDOW_DIR/restarts" "$WINDOW_DIR/adopted"

    log "opening a window of ${hours} h: seat $SEAT, $URL, compose $compose"

    # 0. Already up and healthy (the primary engine since Phase 3): adopt it, and leave it up when the window closes.
    if [ "$(container_state)" = "running healthy" ]; then
        log "adopting the running stack: no Ollama stop, no GPU check, no start; it stays up when the window closes"
        : > "$WINDOW_DIR/adopted"
        UP_IN_PROGRESS=1
        trap on_interrupt INT TERM HUP
    else
        # 1. Free the card of Ollama's resident seat(s). Real use of the server pauses for the window.
        if "$DOCKER" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$OLLAMA_CONTAINER"; then
            local m
            while read -r m; do
                [ -n "$m" ] || continue
                "$DOCKER" exec "$OLLAMA_CONTAINER" ollama stop "$m" >/dev/null 2>&1 && log "stopped Ollama's resident seat $m" || log "could not stop $m"
            done < <("$DOCKER" exec "$OLLAMA_CONTAINER" ollama ps 2>/dev/null | awk 'NR>1 {print $1}')
        else
            log "no running $OLLAMA_CONTAINER container: nothing to unload"
        fi

        # 2. The GPU must be free before the seat is loaded; something other than Ollama may be holding it.
        if command -v "$NVIDIA_SMI" >/dev/null 2>&1; then
            local used="" start
            start="$(date +%s)"
            while [ $(( $(date +%s) - start )) -le "$GPU_WAIT" ]; do
                used="$(gpu_used_mib)"
                if [ -n "$used" ] && [ "$used" -le "$MAX_USED_MIB" ] 2>/dev/null; then break; fi
                sleep "$POLL"
            done
            if ! { [ -n "$used" ] && [ "$used" -le "$MAX_USED_MIB" ] 2>/dev/null; }; then
                die 4 "the GPU still holds ${used:-?} MiB (limit $MAX_USED_MIB) after ${GPU_WAIT}s: something other than Ollama's resident seat is using it; nothing was started"
            fi
            log "GPU idle baseline: ${used} MiB"
        else
            log "no nvidia-smi: GPU idle check skipped"
        fi

        # 3. Start the stack and wait for a healthy container (nvidia-smi inside it passes).
        UP_IN_PROGRESS=1
        trap on_interrupt INT TERM HUP
        if ! dc up -d >>"$WINDOW_DIR/window.log" 2>&1; then
            close_stack; die 5 "docker compose up failed (see $WINDOW_DIR/window.log)"
        fi
        if ! wait_healthy; then
            "$DOCKER" logs --tail 30 "$CONTAINER" >>"$WINDOW_DIR/window.log" 2>&1 || true
            close_stack; die 5 "$CONTAINER was not healthy after ${HEALTH_WAIT}s (state: $(container_state)); its last log lines are in $WINDOW_DIR/window.log"
        fi
        log "$CONTAINER is healthy"

    fi

    # 4. The seat.
    if ! load_seat; then
        "$DOCKER" logs --tail 30 "$CONTAINER" >>"$WINDOW_DIR/window.log" 2>&1 || true
        close_stack; die 6 "the seat $SEAT did not load; the container's last log lines are in $WINDOW_DIR/window.log"
    fi
    log "seat $SEAT is loaded"

    # 5. The trial's own contract check against the running server (never loads a model).
    if ! bash "$here/llamacpp-check.sh" --url "$URL" >>"$WINDOW_DIR/window.log" 2>&1; then
        close_stack; die 7 "llamacpp-check.sh --url $URL reported a FAIL (see $WINDOW_DIR/window.log)"
    fi
    log "llamacpp-check.sh --url: ok"

    # 6. The clock, then the watchdog.
    local deadline
    deadline="$(awk -v n="$(date +%s)" -v h="$hours" 'BEGIN { printf "%d", n + h * 3600 }')"
    echo "$deadline" > "$WINDOW_DIR/deadline"
    if [ "$watch" = 1 ]; then
        if command -v setsid >/dev/null 2>&1; then
            setsid nohup bash "$self" watch >>"$WINDOW_DIR/watch.out" 2>&1 < /dev/null &
        else
            nohup bash "$self" watch >>"$WINDOW_DIR/watch.out" 2>&1 < /dev/null &
        fi
        # The watchdog writes its own pid (watch.pid) as its first act; wait for it so `status` is true at once.
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WINDOW_DIR/watch.pid" ] && break; sleep 0.5; done
        [ -s "$WINDOW_DIR/watch.pid" ] || log "WARNING: the watchdog did not report a pid; see $WINDOW_DIR/watch.out"
    fi
    UP_IN_PROGRESS=0
    trap - INT TERM HUP
    log "window OPEN until $(date -d "@$deadline" -Is 2>/dev/null || echo "epoch $deadline"); watchdog: $([ "$watch" = 1 ] && echo "pid $(cat "$WINDOW_DIR/watch.pid" 2>/dev/null)" || echo "off")"
    return 0
}

# Restarts in the last hour, from the epoch seconds in $WINDOW_DIR/restarts.
restarts_last_hour() {
    local since; since=$(( $(date +%s) - 3600 ))
    [ -f "$WINDOW_DIR/restarts" ] || { echo 0; return; }
    awk -v s="$since" '$1 >= s { n++ } END { print n + 0 }' "$WINDOW_DIR/restarts"
}

cmd_watch() {
    mkdir -p "$WINDOW_DIR"
    echo "$$" > "$WINDOW_DIR/watch.pid"
    find_python || { log "watchdog: no python, cannot read the router; exiting"; exit 2; }
    [ -f "$WINDOW_DIR/deadline" ] || { log "watchdog: no deadline file; exiting"; exit 2; }
    local deadline bad=0 n
    deadline="$(cat "$WINDOW_DIR/deadline")"
    log "watchdog: started (pid $$), polling every ${WATCH_INTERVAL}s"
    while :; do
        if [ -e "$WINDOW_DIR/STOP" ]; then log "watchdog: STOP file found, closing the window"; close_stack; rm -f "$WINDOW_DIR/watch.pid"; exit 0; fi
        if [ "$(date +%s)" -ge "$deadline" ]; then log "watchdog: deadline reached, closing the window"; close_stack; rm -f "$WINDOW_DIR/watch.pid"; exit 0; fi
        if server_ok; then
            bad=0
        else
            bad=$(( bad + 1 ))
            log "watchdog: poll failed ($bad in a row; container: $(container_state))"
        fi
        if [ "$bad" -ge 2 ]; then
            n="$(restarts_last_hour)"
            if [ "$n" -ge "$MAX_RESTARTS" ]; then
                log "watchdog: GAVE UP after $n restarts in the last hour; closing the window"
                date -Is > "$WINDOW_DIR/GAVE-UP"
                "$DOCKER" logs --tail 40 "$CONTAINER" >>"$WINDOW_DIR/window.log" 2>&1 || true
                close_stack; rm -f "$WINDOW_DIR/watch.pid"; exit 1
            fi
            date +%s >> "$WINDOW_DIR/restarts"
            log "watchdog: restarting $CONTAINER (restart $(( n + 1 )) in the last hour)"
            "$DOCKER" logs --tail 20 "$CONTAINER" >>"$WINDOW_DIR/window.log" 2>&1 || true
            "$DOCKER" restart "$CONTAINER" >>"$WINDOW_DIR/window.log" 2>&1 || dc up -d >>"$WINDOW_DIR/window.log" 2>&1 || true
            if wait_healthy && load_seat; then log "watchdog: $CONTAINER is back, seat loaded"; else log "watchdog: $CONTAINER did not come back cleanly"; fi
            bad=0
        fi
        sleep "$WATCH_INTERVAL"
    done
}

cmd_status() {
    find_python || die 2 "a working python3 (or python) is required"
    local state seat deadline left ok=0 pid=""
    state="$(container_state)"
    seat="$(seat_status)"
    [ -f "$WINDOW_DIR/watch.pid" ] && pid="$(cat "$WINDOW_DIR/watch.pid" 2>/dev/null)"
    echo "container: $CONTAINER $state"
    echo "seat:      $SEAT $seat"
    if [ -f "$WINDOW_DIR/deadline" ]; then
        deadline="$(cat "$WINDOW_DIR/deadline")"; left=$(( deadline - $(date +%s) ))
        if [ "$left" -gt 0 ]; then echo "window:    open, $(( left / 3600 )) h $(( left % 3600 / 60 )) min left"; else echo "window:    past its deadline"; fi
    else
        echo "window:    not opened (no $WINDOW_DIR/deadline)"
    fi
    if [ -n "$pid" ] && is_watcher "$pid"; then echo "watchdog:  pid $pid"; else echo "watchdog:  not running"; fi
    echo "restarts:  $(restarts_last_hour) in the last hour"
    [ -e "$WINDOW_DIR/GAVE-UP" ] && echo "GAVE-UP:   $(cat "$WINDOW_DIR/GAVE-UP") (the watchdog gave up and closed the window)"
    [ -e "$WINDOW_DIR/STOP" ] && echo "STOP:      file present"
    if [ -f "$WINDOW_DIR/window.log" ]; then echo "last events:"; tail -n 5 "$WINDOW_DIR/window.log" | sed 's/^/  /'; fi
    [ "$state" = "running healthy" ] && [ "$seat" = "loaded" ] && ok=1
    [ "$ok" = 1 ]
}

cmd_down() {
    command -v "$DOCKER" >/dev/null 2>&1 || die 2 "docker is not installed (or DOCKER does not name it)"
    mkdir -p "$WINDOW_DIR"
    stop_watcher
    close_stack
    rm -f "$WINDOW_DIR/deadline"
    log "window closed"
}

case "${1:-}" in
    up) shift; cmd_up "$@" ;;
    watch) shift; cmd_watch "$@" ;;
    status) shift; cmd_status "$@" ;;
    down) shift; cmd_down "$@" ;;
    *) echo "usage: llamacpp-window.sh up [--hours N] [--no-watch] | status | down   (see the header of this file)" >&2; exit 2 ;;
esac
