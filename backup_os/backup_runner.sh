#!/usr/bin/env bash
set -euo pipefail

START_TS="$(date +%s)"

SHARED_LABEL="${SHARED_LABEL:-BACKUP_SHARED}"
SHARED_DIR="${SHARED_DIR:-/backupos_shared}"

FLAG_FILE="$SHARED_DIR/backup.flag"
REQ_FILE="$SHARED_DIR/backup_request.env"
STATUS_ENV="$SHARED_DIR/backup_status.env"
STATUS_JSON="$SHARED_DIR/backup_status.json"

BACKUP_SCRIPT="${BACKUP_SCRIPT:-/usr/local/sbin/backup_sd.sh}"

log() {
  echo "[$(date '+%F %T')] [runner] $*" >&2
}

format_duration() {
  local secs="$1"
  local h=$((secs / 3600))
  local m=$(((secs % 3600) / 60))
  local s=$((secs % 60))

  if (( h > 0 )); then
    printf "%d Std %d Min" "$h" "$m"
  elif (( m > 0 )); then
    printf "%d Min %d Sek" "$m" "$s"
  else
    printf "%d Sek" "$s"
  fi
}

# 1) Shared-Volume mounten
log "Mount shared volume (LABEL=${SHARED_LABEL}) nach ${SHARED_DIR}..."

mkdir -p "$SHARED_DIR"

if ! mountpoint -q "$SHARED_DIR"; then
  if ! mount -L "$SHARED_LABEL" "$SHARED_DIR"; then
    log "❌ Konnte Volume mit LABEL=${SHARED_LABEL} nicht mounten."
    exit 1
  fi
fi

log "✅ Shared-Volume gemountet."

# 2) Job prüfen
if [[ ! -f "$FLAG_FILE" || ! -f "$REQ_FILE" ]]; then
  log "ℹ️ Kein Backup-Job gefunden (${FLAG_FILE} oder ${REQ_FILE} fehlt) – nichts zu tun."
  exit 0
fi

log "✅ Backup-Job gefunden, lade ENV aus ${REQ_FILE}..."

# 3) ENV laden und exportieren
set -a
# shellcheck source=/dev/null
source "$REQ_FILE"
set +a

# MARKER_DIR für Logs / last_run etc. auf Shared-Dir legen,
# damit das Haupt-OS später alles sehen kann.
export MARKER_DIR="$SHARED_DIR"

MODE="${MODE:-no-health}"
ZERO_FILL="${ZERO_FILL:-false}"
HEALTH_CHECK="${HEALTH_CHECK:-false}"
BOS_MAINTANCE="${BOS_MAINTANCE:-false}"

if "$BOS_MAINTANCE"; then
  exit 1
fi

log "Job-Parameter: MODE=${MODE}, ZERO_FILL=${ZERO_FILL}, HEALTH_CHECK=${HEALTH_CHECK}"
log "Backup-Script: ${BACKUP_SCRIPT}"

if [[ ! -x "$BACKUP_SCRIPT" ]]; then
  log "❌ Backup-Script ${BACKUP_SCRIPT} nicht ausführbar."
  echo "STATE=failed" > "$STATUS_ENV"
  echo "ERROR=backup_script_missing" >> "$STATUS_ENV"
  cat > "$STATUS_JSON" <<EOF
{"state":"failed","error":"backup_script_missing"}
EOF
  echo "failed" > "$FLAG_FILE"
  exit 1
fi

# 4) Backup ausführen
BACKUP_EXIT=0
if ! "$BACKUP_SCRIPT"; then
  BACKUP_EXIT=$?
fi

END_TS="$(date +%s)"
DURATION_SEC=$(( END_TS - START_TS ))
DURATION_STR="$(format_duration "$DURATION_SEC")"
END_HUMAN="$(date '+%d.%m.%Y %H:%M')"

STATE="success"
REASON="ok"

case "$BACKUP_EXIT" in
  0)
    STATE="success"
    REASON="ok"
    ;;
  10)
    # definieren wir gleich im backup_sd.sh als Healthcheck-Error
    STATE="unhealthy"
    REASON="healthcheck_failed"
    ;;
  *)
    STATE="failed"
    REASON="backup_failed"
    ;;
esac

log "Backup abgeschlossen: STATE=${STATE}, EXIT=${BACKUP_EXIT}, Dauer=${DURATION_STR}"

# 5) Status-Dateien schreiben
cat > "$STATUS_ENV" <<EOF
STATE=${STATE}
EXIT_CODE=${BACKUP_EXIT}
REASON=${REASON}
MODE=${MODE}
ZERO_FILL=${ZERO_FILL}
HEALTH_CHECK=${HEALTH_CHECK}
FINISHED_AT="${END_HUMAN}"
DURATION="${DURATION_STR}"
SECONDS=${DURATION_SEC}
EOF

cat > "$STATUS_JSON" <<EOF
{
  "state": "${STATE}",
  "exit_code": ${BACKUP_EXIT},
  "reason": "${REASON}",
  "mode": "${MODE}",
  "zero_fill": ${ZERO_FILL},
  "health_check": ${HEALTH_CHECK},
  "finished_at": "${END_HUMAN}",
  "duration": "${DURATION_STR}",
  "seconds": ${DURATION_SEC}
}
EOF

echo "${STATE}" > "$FLAG_FILE"

log "Status in ${STATUS_ENV} / ${STATUS_JSON} geschrieben."

# 6) Zurück ins Haupt-System
log "Reboot zurück ins Haupt-OS..."
sleep 2
/sbin/reboot now || true
