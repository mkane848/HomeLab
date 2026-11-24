#!/usr/bin/env bash
# ollama-inventory.sh - the dry run of the server's Ollama uninstall: what it would remove, and whether that is safe.
#
# Ollama was removed from the fleet on 2026-11-21 (docs/roadmap.md -> "Ollama removed (2026-11-21)"), but its
# container, its image and the docker_ollama_data volume are still on the server. Deleting them is the owner's
# step, after a dry run and a hash-compare (AGENTS.md -> "Before deleting anything"). This script is that dry run.
# It changes nothing:
#   1. It lists every container whose image is ollama/ollama or whose name contains "ollama", every ollama/ollama
#      image, every volume whose name contains "ollama", and what mounts each volume.
#   2. It checks that nothing still needs them:
#      - no other container mounts an Ollama volume;
#      - the llama.cpp container is running, and every seat loads a GGUF whose sha256 matches its pin in
#        models/server-seats.tsv (llamacpp-check.sh --weights-container <name> --hash; --no-hash skips the re-hash,
#        about a minute for the 20 GB seat).
#   3. When both checks pass, it prints the commands that would delete them, for the owner to read and run. It runs
#      none of them.
# Exit 0: ready, or nothing left to remove. 1: a blocker, named. 2: usage.
#
# Usage:  server/scripts/ollama-inventory.sh [--no-hash] [--container llamacpp-server]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

hash=1
llc=llamacpp-server
while [ $# -gt 0 ]; do
    case "$1" in
        --no-hash) hash=0; shift ;;
        --container) [ $# -ge 2 ] || { echo "usage: $0 [--no-hash] [--container NAME]" >&2; exit 2; }; llc="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "usage: $0 [--no-hash] [--container NAME]" >&2; exit 2 ;;
    esac
done
command -v docker >/dev/null 2>&1 || { echo "[ollama-inventory] docker is not on PATH" >&2; exit 2; }

blockers=()
lower() { tr '[:upper:]' '[:lower:]'; }

# --- 1. what is there ---------------------------------------------------------------------------
containers=()
while IFS=$'\t' read -r name image status; do
    [ -n "$name" ] || continue
    case "$(printf '%s %s' "$name" "$image" | lower)" in
        *ollama*) containers+=("$name"); printf 'container  %s  (%s; %s)\n' "$name" "$image" "$status" ;;
    esac
done < <(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}')

images=()
while IFS=$'\t' read -r ref id size; do
    [ -n "$ref" ] || continue
    case "$ref" in
        ollama/ollama:*|ollama/ollama) images+=("$ref"); printf 'image      %s  (%s, %s)\n' "$ref" "$id" "$size" ;;
    esac
done < <(docker image ls --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}')

volumes=()
while IFS= read -r vol; do
    [ -n "$vol" ] || continue
    case "$(printf '%s' "$vol" | lower)" in
        *ollama*) ;;
        *) continue ;;
    esac
    volumes+=("$vol")
    users="$(docker ps -a --filter "volume=$vol" --format '{{.Names}}' | paste -sd, -)"
    printf 'volume     %s  (mounted by: %s)\n' "$vol" "${users:-nothing}"
    # A volume an Ollama container mounts is fine; any other container mounting it still needs it.
    IFS=',' read -r -a mounted <<< "$users"
    for u in "${mounted[@]}"; do
        [ -n "$u" ] || continue
        keep=1
        for c in "${containers[@]}"; do [ "$u" = "$c" ] && keep=0; done
        [ "$keep" = 1 ] && blockers+=("volume $vol is mounted by $u, which is not an Ollama container")
    done
done < <(docker volume ls --format '{{.Name}}')

if [ ${#containers[@]} -eq 0 ] && [ ${#images[@]} -eq 0 ] && [ ${#volumes[@]} -eq 0 ]; then
    echo "[ollama-inventory] nothing Ollama is left on this server"
    exit 0
fi

# --- 2. does llama.cpp still need anything of it ------------------------------------------------
if [ "$(docker ps --filter "name=^${llc}\$" --format '{{.Names}}')" != "$llc" ]; then
    blockers+=("the llama.cpp container $llc is not running, so its seats' weights cannot be checked (start it: docker compose -f server/docker/docker-compose.llamacpp.yml up -d)")
else
    check=("$here/llamacpp-check.sh" --weights-container "$llc")
    [ "$hash" = 1 ] && check+=(--hash)
    echo "[ollama-inventory] ${check[*]}"
    if ! "${check[@]}"; then
        blockers+=("llamacpp-check.sh failed: a seat's weights are missing or do not match their pin, so Ollama's files may still be the only good copy")
    fi
fi

# --- 3. the verdict, and the commands --------------------------------------------------------------
if [ ${#blockers[@]} -gt 0 ]; then
    echo
    echo "[ollama-inventory] NOT READY - nothing should be deleted yet:"
    for b in "${blockers[@]}"; do echo "  - $b"; done
    exit 1
fi
echo
echo "[ollama-inventory] READY. Nothing has been deleted. To remove it (not reversible; read before running):"
[ ${#containers[@]} -gt 0 ] && echo "  docker rm -f ${containers[*]}"
[ ${#volumes[@]} -gt 0 ] && echo "  docker volume rm ${volumes[*]}"
[ ${#images[@]} -gt 0 ] && echo "  docker image rm ${images[*]}"
[ "$hash" = 0 ] && echo "  (the weights were not re-hashed: run again without --no-hash before deleting the volume)"
exit 0
