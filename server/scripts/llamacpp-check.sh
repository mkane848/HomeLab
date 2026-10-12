#!/usr/bin/env bash
# llamacpp-check.sh - are the llama.cpp trial's contracts kept?
#
# Static (no flags): server/llamacpp/models.ini against models/server-seats.tsv -
# pinned weights blobs, explicit context equal to the seat table, one slot, a CPU
# seat with no GPU layers. Optional:
#   --ollama-url http://localhost:11434   compare sampling parameters with Ollama's
#   --url http://localhost:8090           check a running llama-server (/health,
#                                         /props n_ctx and total_slots; never
#                                         loads a model)
# See llamacpp_check.py for the detail and docs/llamacpp-trial.md for where it
# sits in the trial. Needs python3 (standard on Ubuntu Server); nothing else.
# Exit 1 on any FAIL. Run it with `bash` if the exec bit was lost in a copy
# (./make-executable.sh restores it).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
    echo "[llamacpp-check] python3 is required" >&2
    exit 2
fi
exec python3 "$here/llamacpp_check.py" "$@"
