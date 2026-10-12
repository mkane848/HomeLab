#!/usr/bin/env bash
# bake-models.sh - bake num_ctx into the server's seats, under the SAME tags as the desktop
#
# The server-side half of desktop/scripts/startup.ps1 ($contextModels + $derivedModels).
# Same tag, same num_ctx, so one tests/run-tasks-models.tsv row covers both hosts and
# opencode.jsonc's limit.context matches what the host really serves. That is one
# contract with two halves: change a number here and in startup.ps1 and in the
# ollama-server / ollama-desktop blocks of opencode/global/opencode.jsonc together,
# or the truncation bug (docs/troubleshooting.md) comes back.
#
# Usage:
#   bake-models.sh              # bake every table entry that is installed
#   bake-models.sh qwen3:8b     # bake only the named entries (tag or derived name)
#   bake-models.sh --list       # show the table and what is installed
#   bake-models.sh --dry-run    # show what would be created
#
# It never pulls. Install first: ./server/scripts/install-model.sh <tag>.
# Idempotent: re-baking a baked tag writes the same parameters again.

set -euo pipefail

CONTAINER="ollama-server"
DRY_RUN=0
LIST=0

# tag|num_ctx - mirrors startup.ps1 $contextModels for the seats installed on the server.
BAKES=(
    "qwen3.6:35b-a3b-coding|65536"
    "qwen3:8b|32768"
    "qwen2.5-coder:3b|16384"
)

# name|from|num_ctx|num_gpu - mirrors startup.ps1 $derivedModels. num_gpu 0 keeps the
# model on the CPU, so it can be the small (titles) model beside qwen3.6, which takes
# every byte of VRAM it can (docs/main-seat-trial.md -> "Second experiment").
DERIVED=(
    "qwen2.5-coder-3b-cpu|qwen2.5-coder:3b|16384|0"
)

die() { echo "[bake-models] ERROR: $*" >&2; exit 1; }

installed_tags() {
    docker exec "$CONTAINER" ollama list | awk 'NR>1 { print $1 }'
}

# create <name> <from> <num_ctx> [num_gpu]
# The Modelfile is written inside the container: `docker exec` without -i drops stdin.
create() {
    local name="$1" from="$2" ctx="$3" gpu="${4:-}"
    local lines="'FROM $from' 'PARAMETER num_ctx $ctx'"
    [[ -n "$gpu" ]] && lines="$lines 'PARAMETER num_gpu $gpu'"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[bake-models] (dry-run) create $name FROM $from num_ctx=$ctx${gpu:+ num_gpu=$gpu}"
        return 0
    fi
    echo "[bake-models] $name <- $from  num_ctx=$ctx${gpu:+ num_gpu=$gpu}"
    docker exec "$CONTAINER" sh -c "printf '%s\n' $lines > /tmp/Modelfile-bake && ollama create '$name' -f /tmp/Modelfile-bake && rm -f /tmp/Modelfile-bake" >/dev/null
    docker exec "$CONTAINER" ollama show "$name" --parameters | sed 's/^/[bake-models]     /'
}

main() {
    local only=() arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=1 ;;
            --list)    LIST=1 ;;
            -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print } /^set /{exit}' "$0"; exit 0 ;;
            *)         only+=("$arg") ;;
        esac
    done

    command -v docker >/dev/null 2>&1 || die "docker not found on this machine."
    docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || die "$CONTAINER is not running (./server/scripts/startup.sh)."

    local have entry tag ctx name from gpu mark
    have="$(installed_tags)"

    if [[ "$LIST" -eq 1 ]]; then
        for entry in "${BAKES[@]}"; do
            IFS='|' read -r tag ctx <<<"$entry"
            mark="missing"; grep -qxF "$tag" <<<"$have" && mark="installed"
            printf '  %-28s num_ctx=%-6s %s\n' "$tag" "$ctx" "$mark"
        done
        for entry in "${DERIVED[@]}"; do
            IFS='|' read -r name from ctx gpu <<<"$entry"
            mark="not built"; grep -qxF "$name" <<<"$have" && mark="built"
            printf '  %-28s num_ctx=%-6s num_gpu=%s from %s (%s)\n' "$name" "$ctx" "$gpu" "$from" "$mark"
        done
        exit 0
    fi

    wanted() { [[ ${#only[@]} -eq 0 ]] || printf '%s\n' "${only[@]}" | grep -qxF "$1"; }

    local baked=0 skipped=0
    for entry in "${BAKES[@]}"; do
        IFS='|' read -r tag ctx <<<"$entry"
        wanted "$tag" || continue
        if grep -qxF "$tag" <<<"$have"; then
            create "$tag" "$tag" "$ctx"; baked=$((baked + 1))
        else
            echo "[bake-models] skip $tag: not installed (install-model.sh $tag)"; skipped=$((skipped + 1))
        fi
    done

    # Derived models are built after the loop so their base already carries its context.
    # The base is re-read: a base installed seconds ago by the loop above is not in $have.
    have="$(installed_tags)"
    for entry in "${DERIVED[@]}"; do
        IFS='|' read -r name from ctx gpu <<<"$entry"
        wanted "$name" || continue
        if grep -qxF "$from" <<<"$have"; then
            create "$name" "$from" "$ctx" "$gpu"; baked=$((baked + 1))
        else
            echo "[bake-models] skip $name: base $from is not installed"; skipped=$((skipped + 1))
        fi
    done

    echo "[bake-models] done: $baked created, $skipped skipped."
}

main "$@"
