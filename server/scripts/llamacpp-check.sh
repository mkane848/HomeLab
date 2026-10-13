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
# python3 if it runs, else python. "Runs" matters on Windows, where python3 can be the Microsoft
# Store placeholder: on PATH, but it exits 49 instead of running anything.
py=""
for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
        py="$cand"
        break
    fi
done
if [ -z "$py" ]; then
    echo "[llamacpp-check] a working python3 (or python) is required" >&2
    exit 2
fi
exec "$py" "$here/llamacpp_check.py" "$@"
