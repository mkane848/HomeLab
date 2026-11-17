# server/scripts/llamacpp-auth.sh - sourced, not run. The API key the server's scripts send to llama-server.
#
# llama-server started with --api-key-file (server/docker/docker-compose.llamacpp.yml) answers only /health without
# `Authorization: Bearer <key>`; everything else is HTTP 401. docs/engine-api-keys.md is the runbook.
#
# Where the key comes from, first match wins:
#   1. $LLAMACPP_API_KEY
#   2. the file named by $LLAMACPP_API_KEY_FILE, default ~/.config/llamacpp/api-key (the same file the compose
#      mounts). The first line that is not blank or a # comment is the fleet's key; later lines are other clients'.
# No key: no header (an engine without a key still answers; one with a key answers 401, which the caller reports).
#
# llamacpp_curl ARGS...   runs ${CURL:-curl} ARGS with the header. The header goes through a file descriptor
#                         (-H @/dev/fd/N), so the key is never on a command line (ps) or in a log.

llamacpp_api_key() {
    if [ -n "${LLAMACPP_API_KEY:-}" ]; then printf '%s' "$LLAMACPP_API_KEY"; return 0; fi
    local f="${LLAMACPP_API_KEY_FILE:-$HOME/.config/llamacpp/api-key}" line
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        case "$line" in ''|'#'*) continue ;; esac
        printf '%s' "$line"; return 0
    done < "$f"
}

llamacpp_curl() {
    local key
    key="$(llamacpp_api_key)"
    if [ -n "$key" ]; then
        "${CURL:-curl}" -H @<(printf 'Authorization: Bearer %s\n' "$key") "$@"
    else
        "${CURL:-curl}" "$@"
    fi
}
