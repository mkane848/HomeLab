#!/usr/bin/env bash
# make-executable.sh — Give all project scripts the executable bit.
#
# Why this exists: files copied from Windows (e.g. via scp) don't carry the
# executable bit, so running ./server/scripts/startup.sh fails with
# "Permission denied". Run this once after copying the repo to your server.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FILES=(
    profiles/*.sh
    server/scripts/*.sh
    models/*.sh
    make-executable.sh
)

printf "Marking executables...\n"
for pattern in "${FILES[@]}"; do
    for file in $pattern; do
        if [[ -f "$file" ]]; then
            chmod +x "$file"
            printf "  +x %s\n" "$file"
        fi
    done
done

printf "\nDone. You can now run:\n"
printf "  %s/server/scripts/startup.sh\n" "$SCRIPT_DIR"