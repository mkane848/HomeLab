#!/usr/bin/env bash
# Nightly backup of the household's data: the tracker (Grocy's /config volume: SQLite database, settings) and,
# when it is installed, the chat (Open WebUI's data volume: accounts, chats, the tool's stored settings).
# Phase 1 of docs/household-assistant.md; runbook docs/household/phase1.md -> "Backups".
#
# Needs only the docker group, no sudo. Writes ~/backups/household/grocy-<UTC stamp>.tar.gz and
# openwebui-<UTC stamp>.tar.gz, and keeps the newest KEEP of each (default 14). A missing chat volume is not an
# error (phase 1 alone has none); a missing tracker volume is. NOT in the backup: WEBUI_SECRET_KEY, which lives in
# the compose .env and without which the chat's stored settings cannot be decrypted. Keep a copy of it yourself. The desktop pulls the newest copy off the server
# (desktop/scripts/pull-household-backup.ps1): a copy that lives only on the server is not a backup.
#
# Cron (crontab -e as the server user, no sudo):
#   15 3 * * * $HOME/HomeLab/server/household/backup.sh >> $HOME/backups/household/backup.log 2>&1
set -euo pipefail

VOLUME="${HOUSEHOLD_VOLUME:-household_grocy_config}"
CHAT_VOLUME="${HOUSEHOLD_CHAT_VOLUME:-household_openwebui_data}"
DEST="${HOUSEHOLD_BACKUP_DIR:-$HOME/backups/household}"
KEEP="${KEEP:-14}"
CONTAINER="${HOUSEHOLD_CONTAINER:-household-grocy}"
CHAT_CONTAINER="${HOUSEHOLD_CHAT_CONTAINER:-household-openwebui}"

mkdir -p "$DEST"
docker volume inspect "$VOLUME" >/dev/null 2>&1 || { echo "backup: volume $VOLUME not found" >&2; exit 1; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)"

# One container is paused at a time; the trap puts it back if anything fails in between.
paused=""
trap '[ -n "$paused" ] && docker unpause "$paused" >/dev/null || true' EXIT

# backup_volume <prefix> <volume> <container>: <prefix>-<stamp>.tar.gz in $DEST, the newest $KEEP kept.
backup_volume() {
  local prefix="$1" volume="$2" container="$3" out
  out="$prefix-$stamp.tar.gz"
  # Pause the container so SQLite is not mid-write while the copy is taken (seconds; the web UI just waits).
  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false)" = "true" ]; then
    docker pause "$container" >/dev/null && paused="$container"
  fi
  docker run --rm -v "$volume":/data:ro -v "$DEST":/backup alpine:3.20 \
    tar -czf "/backup/$out.partial" -C /data .
  mv "$DEST/$out.partial" "$DEST/$out"
  if [ -n "$paused" ]; then docker unpause "$paused" >/dev/null; paused=""; fi

  # A backup that cannot be listed is not a backup.
  tar -tzf "$DEST/$out" >/dev/null
  ls -1t "$DEST"/"$prefix"-*.tar.gz | tail -n +"$((KEEP + 1))" | xargs -r rm -f
  echo "backup: $DEST/$out ($(du -h "$DEST/$out" | cut -f1)), keeping $KEEP"
}

backup_volume grocy "$VOLUME" "$CONTAINER"
if docker volume inspect "$CHAT_VOLUME" >/dev/null 2>&1; then
  backup_volume openwebui "$CHAT_VOLUME" "$CHAT_CONTAINER"
else
  echo "backup: no $CHAT_VOLUME volume, so the chat is not backed up (expected before phase 2)"
fi
