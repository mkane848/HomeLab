#!/usr/bin/env bash
# select-model.sh - Interactive profile selection
#
# Discovers profiles dynamically from profiles/*.sh. Anything in
# profiles/parked/ is deliberately excluded - see profiles/parked/README.md.
#
# This used to carry a hardcoded list of nine profiles. It went stale: it never
# listed the dev-workflow-* trio that became the defaults, and it kept offering
# server profiles after the server stopped POSTing. Dynamic discovery means
# parking or unparking a profile is a `git mv` and nothing else.
#
# Uses fzf if available, otherwise a numbered menu.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Discover live profiles -------------------------------------------------
mapfile -t PROFILE_FILES < <(find "$SCRIPT_DIR" -maxdepth 1 -name "dev-*.sh" -type f | sort)

if [[ ${#PROFILE_FILES[@]} -eq 0 ]]; then
    echo "No profiles found in ${SCRIPT_DIR}." >&2
    echo "Check profiles/parked/ - they may all be parked." >&2
    exit 1
fi

# Description = text after " - " on the first comment line below the shebang,
# which every profile header already follows.
describe() {
    local f="$1" desc
    desc=$(sed -n '2s/^# *[a-z0-9._-]*\.sh *- *//p' "$f")
    [[ -z "$desc" ]] && desc=$(sed -n '2s/^# *//p' "$f")
    echo "${desc:-no description}"
}

menu_line() {
    local i="$1" f="${PROFILE_FILES[$1 - 1]}"
    printf "%d) %s - %s" "$i" "$(basename "$f")" "$(describe "$f")"
}

fzf_menu() {
    local choice
    choice=$(for i in $(seq 1 ${#PROFILE_FILES[@]}); do menu_line "$i"; echo; done \
        | fzf --prompt="Select profile > " --height=40% --reverse)
    echo "$choice" | cut -d')' -f1 | tr -d ' '
}

fallback_menu() {
    echo "" >&2
    echo "  Profile Selection" >&2
    echo "  -------------------------------------------" >&2
    local i
    for i in $(seq 1 ${#PROFILE_FILES[@]}); do
        printf "  [%d] %-26s %s\n" "$i" \
            "$(basename "${PROFILE_FILES[$i - 1]}")" \
            "$(describe "${PROFILE_FILES[$i - 1]}")" >&2
    done
    echo "" >&2
    read -rp "  Enter choice [1-${#PROFILE_FILES[@]}]: " choice
    echo "$choice"
}

# --- Main -------------------------------------------------------------------
if command -v fzf &>/dev/null; then
    CHOICE=$(fzf_menu)
else
    CHOICE=$(fallback_menu)
fi

if [[ -z "${CHOICE}" ]] || ! [[ "$CHOICE" =~ ^[0-9]+$ ]] \
   || (( CHOICE < 1 || CHOICE > ${#PROFILE_FILES[@]} )); then
    echo "Invalid selection." >&2
    exit 1
fi

PROFILE_PATH="${PROFILE_FILES[$CHOICE - 1]}"

# This script runs in a child process, so sourcing the profile here would lose
# every export when it exits. With --print, emit the command for the caller to
# eval; otherwise show it. Usage: eval "$(bash profiles/select-model.sh --print)"
if [[ "${1:-}" == "--print" ]]; then
    printf 'source %q\n' "$PROFILE_PATH"
    exit 0
fi
echo ""
echo "Selected: $(basename "$PROFILE_PATH")"
echo "This script cannot set variables in your shell. Run:"
echo "  source $PROFILE_PATH"
echo "or: eval \"\$(bash profiles/select-model.sh --print)\""
