#!/usr/bin/env bash
# install-model.sh — Install models into the server's Ollama container from the catalog
#
# Usage:
#   install-model.sh                 # list usage
#   install-model.sh --list          # show catalog (all groups)
#   install-model.sh --list coder    # show one group
#   install-model.sh --info <tag>    # show catalog entry for one model
#   install-model.sh <tag> [...]     # pull specific tags
#   install-model.sh <group> [...]   # pull a whole group (autocomplete/coder/reasoner/general/creative/embed)
#   install-model.sh all             # pull every catalog model
#   install-model.sh --profile       # pull whatever the active profile asked for (DEV_SERVER_MODELS)
#
# Options:
#   --ctx N         after pulling, also create a derived <tag>-Nk model with num_ctx baked
#                   (same pattern as the desktop's deepseek-r1-16k). Only needed when you
#                   want a per-model context different from the server default.
#   --dry-run       show what would be pulled without doing it

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_DIR="$SCRIPT_DIR/../docker"

# shellcheck source=../../models/catalog.sh
source "$PROJECT_ROOT/models/catalog.sh"

CONTAINER="ollama-server"
CTX=""
DRY_RUN=0

die() { echo "[install-model] ERROR: $*" >&2; exit 1; }

usage() {
    awk 'NR>1 && /^#/ && $0 !~ /shellcheck/ { sub(/^# ?/, ""); print }' "$0"
}

check_docker() {
    command -v docker >/dev/null 2>&1 || die "docker not found on this machine."
}

ensure_container() {
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        echo "[install-model] $CONTAINER is not running. Starting it with docker compose..."
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "[install-model] (dry-run) would run: docker compose -f $DOCKER_DIR/docker-compose.yml up -d"
        else
            docker compose -f "$DOCKER_DIR/docker-compose.yml" up -d
            sleep 3
        fi
    fi
    docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || die "$CONTAINER still not running. Check 'docker ps' and logs."
}

ollama_exec() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[install-model] (dry-run) docker exec $CONTAINER ollama $*"
        return 0
    fi
    docker exec "$CONTAINER" ollama "$@"
}

ollama_pull() {
    local tag="$1"
    local size_gb class hosts ctx suggested_alias
    size_gb=$(catalog_field "$tag" size_gb || echo "?")
    class=$(catalog_field "$tag" class || echo "?")
    hosts=$(catalog_field "$tag" hosts || echo "?")

    echo ""
    echo "[install-model] Pulling $tag  (${size_gb}G weights, class=$class, hosts=$hosts)"
    if [[ "$hosts" != "all" ]] && [[ "$hosts" != *"server"* ]]; then
        echo "[install-model] note: $tag is not in the catalog's 'server' host list ($hosts)."
    fi
    ollama_exec pull "$tag"

    if [[ -n "$CTX" ]]; then
        local derived="${tag}-${CTX}k"
        echo "[install-model] Creating derived model $derived (num_ctx $CTX)..."
        ollama_exec create "$derived" <<EOF >/dev/null
FROM $tag
PARAMETER num_ctx $CTX
EOF
        echo "[install-model] ok: $derived serves $tag at $CTX context."
    fi
}

catalog_tags() {
    awk -F '\t' 'NR>1 { print $1 }' "$CATALOG_TSV"
}

expand_target() {
    # Print catalog tags for a tag-or-group target (empty if neither)
    local target="$1"
    if catalog_has_tag "$target"; then
        echo "$target"
        return 0
    fi
    if catalog_group_exists "$target"; then
        catalog_group_rows "$target" | cut -f1
        return 0
    fi
    return 1
}

main() {
    local targets=() target line
    local profile_mode=0

    [[ $# -eq 0 ]] && { usage; exit 0; }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)
                catalog_list "${2:-}"
                exit 0
                ;;
            --info)
                line=$(catalog_line "${2:?--info requires a tag}") || true
                [[ -z "$line" ]] && die "no catalog entry for '${2}'"
                echo "$line"
                exit 0
                ;;
            --ctx)
                shift
                CTX="$1"
                [[ "$CTX" =~ ^[0-9]+$ ]] || die "--ctx expects a number (e.g. 32768)"
                ;;
            --profile)
                profile_mode=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            *)
                targets+=("$1")
                ;;
        esac
        shift
    done

    if [[ "$profile_mode" -eq 1 ]]; then
        [[ -z "${DEV_SERVER_MODELS:-}" ]] && die "DEV_SERVER_MODELS is not set. Source a profile first (e.g. source profiles/dev-server-all.sh)."
        # shellcheck disable=SC2206
        targets=($DEV_SERVER_MODELS)
    fi

    [[ ${#targets[@]} -eq 0 ]] && die "no targets given (tags/groups/all). See usage above."

    check_docker
    ensure_container

    for target in "${targets[@]}"; do
        local found=0
        if [[ "$target" == "all" ]]; then
            for tag in $(catalog_tags); do
                found=1
                ollama_pull "$tag"
            done
        else
            for tag in $(expand_target "$target" || true); do
                found=1
                ollama_pull "$tag"
            done
        fi
        [[ "$found" -eq 0 ]] && echo "[install-model] nothing to install for '$target' (not a tag or group)."
    done

    echo ""
    echo "[install-model] Done. Verify with: ./server/scripts/status.sh"
}

main "$@"