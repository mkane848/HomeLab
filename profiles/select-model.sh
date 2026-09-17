#!/usr/bin/env bash
# select-model.sh - Interactive model tier selection
# Uses fzf if available, otherwise falls back to numbered menu

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -A PROFILES=(
    ["1"]="dev-quick.sh|Qwen 7b autocomplete only (zero cost)"
    ["2"]="dev-coder.sh|Server Qwen 14b coder only"
    ["3"]="dev-server-all.sh|Everything on server (coder + reasoner)"
    ["4"]="dev-desktop-only.sh|All local on this PC (ROCm) - use when server is down"
    ["5"]="dev-local-only.sh|Qwen (server) + DeepSeek (desktop), zero cloud"
    ["6"]="dev-embeddings.sh|Server autocomplete + embeddings (semantic search)"
    ["7"]="dev-go-only.sh|Qwen + OpenCode Go (test cloud models)"
    ["8"]="dev-node3.sh|Activate node3's 3080 FE node (future)"
    ["9"]="dev-full.sh|Everything online (server + desktop + Go)"
)

show_menu() {
    echo ""
    echo "  Model Tier Selection"
    echo "  -------------------------------------------"
for i in $(seq 1 9); do
        IFS='|' read -r file desc <<< "${PROFILES[$i]}"
        printf "  [%d] %-20s %s\n" "$i" "$file" "$desc"
    done
    echo ""
}

fzf_menu() {
    local choice
    choice=$(for i in $(seq 1 9); do
        IFS='|' read -r file desc <<< "${PROFILES[$i]}"
        echo "${i}) ${file} - ${desc}"
    done | fzf --prompt="Select profile > " --height=40% --reverse)

    echo "$choice" | cut -d')' -f1 | tr -d ' '
}

fallback_menu() {
    show_menu
    read -rp "  Enter choice [1-9]: " choice
    echo "$choice"
}

# Main
if command -v fzf &>/dev/null; then
    CHOICE=$(fzf_menu)
else
    CHOICE=$(fallback_menu)
fi

if [[ -z "${CHOICE}" || ! "${PROFILES[${CHOICE}]+exists}" ]]; then
    echo "Invalid selection." >&2
    exit 1
fi

IFS='|' read -r PROFILE_FILE _ <<< "${PROFILES[$CHOICE]}"
PROFILE_PATH="${SCRIPT_DIR}/${PROFILE_FILE}"

if [[ ! -f "$PROFILE_PATH" ]]; then
    echo "Profile not found: ${PROFILE_PATH}" >&2
    exit 1
fi

echo ""
echo "Activating: ${PROFILE_FILE}"
echo "------------------------------------------"
source "$PROFILE_PATH"
echo "Done. Run your startup scripts next."