#!/usr/bin/env bash
# bake-models.sh - put the server's seats into the shape the desktop measured.
#
# Reads models/server-seats.tsv and, for each seat, inside the ollama-server
# container:
#   1. pulls the tag if it is missing (source=pull); an import seat that is
#      missing is reported with what to do, never guessed at;
#   2. bakes num_ctx (and num_gpu for a derived CPU model) into the SAME tag name
#      the desktop uses (desktop/scripts/startup.ps1 does the same with
#      `ollama create <tag>` FROM <tag>), so one run-tasks-models.tsv row and one
#      opencode.jsonc entry cover both hosts;
#   3. verifies: the baked num_ctx, and the weights blob against the desktop's
#      sha256. A different blob is a different model - its results are a new
#      era - so it is reported, not hidden.
#
# Usage (on the server, from the repo root or anywhere):
#   ./server/scripts/bake-models.sh              # every seat
#   ./server/scripts/bake-models.sh --only qwen3.6:35b-a3b-coding
#   ./server/scripts/bake-models.sh --dry-run    # print what it would do
#   ./server/scripts/bake-models.sh --no-pull    # bake/verify what is already there
#
# Exit: 0 when every seat present was baked and verified (missing import seats
# and weight differences are listed as warnings); 1 on a failed pull or bake, or
# a baked num_ctx that does not read back.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEATS="${BAKE_SEATS_FILE:-$PROJECT_ROOT/models/server-seats.tsv}"
CONTAINER="${BAKE_CONTAINER:-ollama-server}"
DRY_RUN=0
NO_PULL=0
ONLY=""

die() { echo "[bake] ERROR: $*" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print } NR>1 && !/^#/ { exit }' "$0"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-pull) NO_PULL=1 ;;
        --only) shift; [[ $# -gt 0 ]] || die "--only needs a tag"; ONLY="$1" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
    shift
done

[[ -f "$SEATS" ]] || die "seat list not found: $SEATS"
command -v docker >/dev/null 2>&1 || die "docker not found on this machine."
if [[ "$DRY_RUN" -eq 0 ]]; then
    docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" ||
        die "$CONTAINER is not running. Start it: docker compose -f server/docker/docker-compose.yml up -d"
fi

# Run a command in the container. In a dry run, print it instead.
in_container() {
    if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) docker exec $CONTAINER $*"; return 0; fi
    docker exec "$CONTAINER" "$@"
}

# `ollama create` reads its Modelfile from a file inside the container, so the
# Modelfile goes in on stdin, which needs `docker exec -i`. Without -i the
# heredoc never reaches the container (install-model.sh --ctx had that bug).
create_model() {
    local name="$1" modelfile="$2"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  (dry-run) docker exec -i $CONTAINER ollama create $name, Modelfile:"
        printf '%s\n' "$modelfile" | sed 's/^/      /'
        return 0
    fi
    printf '%s\n' "$modelfile" |
        docker exec -i "$CONTAINER" sh -c 'cat > /tmp/Modelfile.bake && ollama create "$1" -f /tmp/Modelfile.bake && rm -f /tmp/Modelfile.bake' _ "$name" >/dev/null
}

installed=""
if [[ "$DRY_RUN" -eq 0 ]]; then
    installed="$(docker exec "$CONTAINER" ollama list | awk 'NR>1 { print $1 }')"
fi
has_tag() {
    local t="$1"
    [[ "$t" == *:* ]] || t="$t:latest"
    printf '%s\n' "$installed" | grep -qx -- "$t"
}

failures=0
warnings=()
summary=()

while IFS=$'\t' read -r tag num_ctx num_gpu from weights source note; do
    [[ -z "$tag" || "$tag" == \#* || "$tag" == "tag" ]] && continue
    [[ -n "$ONLY" && "$tag" != "$ONLY" ]] && continue
    echo ""
    gpu_note=""
    [[ "$num_gpu" != "-" ]] && gpu_note=", num_gpu=$num_gpu"
    echo "[bake] $tag  (source=$source, num_ctx=$num_ctx$gpu_note) - $note"

    base="$tag"
    case "$source" in
        pull)
            if [[ "$DRY_RUN" -eq 1 ]] || ! has_tag "$tag"; then
                if [[ "$NO_PULL" -eq 1 ]]; then
                    warnings+=("$tag: missing and --no-pull given; skipped")
                    summary+=("$tag	skipped (missing)")
                    continue
                fi
                echo "[bake]   pulling $tag"
                in_container ollama pull "$tag" || { failures=$((failures + 1)); summary+=("$tag	PULL FAILED"); continue; }
            fi
            ;;
        import)
            if [[ "$DRY_RUN" -eq 1 ]] || ! has_tag "$tag"; then
                warnings+=("$tag: the desktop copy is a local GGUF import ($weights). Copy that GGUF to the server and run 'ollama create $tag' FROM it, or 'ollama pull $tag' and accept different weights (a new era for this seat). Then re-run with --only $tag.")
                summary+=("$tag	skipped (import: see warning)")
                continue
            fi
            ;;
        derived)
            [[ "$from" != "-" ]] || die "$tag is derived but has no 'from' in $SEATS"
            if [[ "$DRY_RUN" -eq 0 ]] && ! has_tag "$from"; then
                failures=$((failures + 1)); summary+=("$tag	FAILED (base $from missing)"); continue
            fi
            base="$from"
            ;;
        *) die "$tag: unknown source '$source' in $SEATS" ;;
    esac

    if [[ "$num_ctx" != "-" ]]; then
        mf="FROM $base"$'\n'"PARAMETER num_ctx $num_ctx"
        [[ "$num_gpu" != "-" ]] && mf+=$'\n'"PARAMETER num_gpu $num_gpu"
        echo "[bake]   baking num_ctx=$num_ctx$gpu_note into $tag"
        create_model "$tag" "$mf" || { failures=$((failures + 1)); summary+=("$tag	BAKE FAILED"); continue; }
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        summary+=("$tag	(dry run)")
        continue
    fi

    # Verify what the container now serves under this tag.
    got_ctx="$(docker exec "$CONTAINER" ollama show "$tag" --parameters 2>/dev/null | awk '$1 == "num_ctx" { print $2 }' | tail -n 1)"
    if [[ "$num_ctx" != "-" && "$got_ctx" != "$num_ctx" ]]; then
        failures=$((failures + 1)); summary+=("$tag	FAILED (num_ctx reads '${got_ctx:-none}', expected $num_ctx)"); continue
    fi
    blob="$(docker exec "$CONTAINER" ollama show "$tag" --modelfile 2>/dev/null | awk '/^FROM / { print $2; exit }' | sed -n 's#.*sha256[-:]\([0-9a-f]\{64\}\).*#sha256:\1#p')"
    if [[ -z "$blob" ]]; then
        summary+=("$tag	baked; weights unknown (no blob in modelfile)")
    elif [[ "$blob" == "$weights" ]]; then
        summary+=("$tag	ok; weights match the desktop")
    else
        warnings+=("$tag: weights $blob differ from the desktop's $weights - a different model; record its results as a new era")
        summary+=("$tag	ok; WEIGHTS DIFFER from the desktop")
    fi
done < "$SEATS"

echo ""
echo "[bake] summary"
for s in "${summary[@]}"; do printf '  %s\n' "$s"; done
if [[ ${#warnings[@]} -gt 0 ]]; then
    echo ""
    echo "[bake] warnings"
    for w in "${warnings[@]}"; do printf '  - %s\n' "$w"; done
fi
[[ "$failures" -eq 0 ]] || { echo ""; echo "[bake] $failures failure(s)"; exit 1; }
exit 0
