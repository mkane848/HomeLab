#!/usr/bin/env bash
# Nightly backup of the household tracker's data (Grocy's /config volume: SQLite database, settings).
# Phase 1 of docs/household-assistant.md; runbook docs/household/phase1.md -> "Backups".
#
# Needs only the docker group, no sudo. Writes ~/backups/household/grocy-<UTC stamp>.tar.gz and keeps the
# newest KEEP (default 14). The desktop pulls the newest copy off the server
# (desktop/scripts/pull-household-backup.ps1): a copy that lives only on the server is not a backup.
#
# Cron (crontab -e as the server user, no sudo):
#   15 3 * * * $HOME/HomeLab/server/household/backup.sh >> $HOME/backups/household/backup.log 2>&1
set -euo pipefail

VOLUME="${HOUSEHOLD_VOLUME:-household_grocy_config}"
DEST="${HOUSEHOLD_BACKUP_DIR:-$HOME/backups/household}"
KEEP="${KEEP:-14}"
CONTAINER="${HOUSEHOLD_CONTAINER:-household-grocy}"

mkdir -p "$DEST"
docker volume inspect "$VOLUME" >/dev/null 2>&1 || { echo "backup: volume $VOLUME not found" >&2; exit 1; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="grocy-$stamp.tar.gz"

# Pause the container so SQLite is not mid-write while the copy is taken (seconds; the web UI just waits).
paused=0
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = "true" ]; then
  docker pause "$CONTAINER" >/dev/null && paused=1
fi
trap '[ "$paused" = 1 ] && docker unpause "$CONTAINER" >/dev/null || true' EXIT

docker run --rm -v "$VOLUME":/data:ro -v "$DEST":/backup alpine:3.20 \
  tar -czf "/backup/$out.partial" -C /data .
mv "$DEST/$out.partial" "$DEST/$out"

if [ "$paused" = 1 ]; then docker unpause "$CONTAINER" >/dev/null; paused=0; fi

# A backup that cannot be listed is not a backup.
tar -tzf "$DEST/$out" >/dev/null
ls -1t "$DEST"/grocy-*.tar.gz | tail -n +"$((KEEP + 1))" | xargs -r rm -f
echo "backup: $DEST/$out ($(du -h "$DEST/$out" | cut -f1)), keeping $KEEP"
