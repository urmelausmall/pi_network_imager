#!/usr/bin/env bash
set -euo pipefail


wait_for_time_sync() {
  local max=120
  for ((i=1; i<=max; i++)); do
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi true; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if ! wait_for_time_sync; then
  echo "[backup] WARN: Zeit nach 120s nicht synchron – fahre trotzdem fort: $(date)"
fi


START_TS="$(date +%s)"

SHARED_LABEL="${SHARED_LABEL:-BACKUP_SHARED}"
SHARED_DIR="${SHARED_DIR:-/backupos_shared}"

FLAG_FILE="$SHARED_DIR/backup.flag"
REQ_FILE="$SHARED_DIR/backup_request.env"
STATUS_ENV="$SHARED_DIR/backup_status.env"
STATUS_JSON="$SHARED_DIR/backup_status.json"

BACKUP_SCRIPT="${BACKUP_SCRIPT:-/usr/local/sbin/backup_sd.sh}"

log() { echo "[$(date '+%F %T')] [runner] $*" >&2; }

format_duration() {
  local secs="$1"
  local h=$((secs / 3600))
  local m=$(((secs % 3600) / 60))
  local s=$((secs % 60))
  if (( h > 0 )); then printf "%d Std %d Min" "$h" "$m"
  elif (( m > 0 )); then printf "%d Min %d Sek" "$m" "$s"
  else printf "%d Sek" "$s"
  fi
}

write_status() {
  local state="$1"
  local exit_code="$2"
  local reason="$3"

  local end_ts end_human duration_sec duration_str
  end_ts="$(date +%s)"
  duration_sec=$(( end_ts - START_TS ))
  duration_str="$(format_duration "$duration_sec")"
  end_human="$(date '+%d.%m.%Y %H:%M')"

  mkdir -p "$SHARED_DIR" || true

  cat > "$STATUS_ENV" <<EOF
STATE=${state}
EXIT_CODE=${exit_code}
REASON=${reason}
FINISHED_AT="${end_human}"
DURATION="${duration_str}"
SECONDS=${duration_sec}
EOF

  cat > "$STATUS_JSON" <<EOF
{
  "state": "${state}",
  "exit_code": ${exit_code},
  "reason": "${reason}",
  "finished_at": "${end_human}",
  "duration": "${duration_str}",
  "seconds": ${duration_sec}
}
EOF

  echo "${state}" > "$FLAG_FILE" || true
}

final_reboot() {
  log "Reboot zurück ins Haupt-OS..."
  sync
  sleep 2

  # 1) systemd (bevorzugt)
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl reboot --force --no-wall || true
  fi

  # 2) klassische Reboot-Varianten (Fallbacks)
  /usr/bin/sudo /sbin/reboot \
    || /usr/bin/sudo /usr/sbin/reboot \
    || /usr/bin/sudo reboot \
    || /usr/bin/sudo shutdown -r now \
    || true
}

# Fail-safe: egal was passiert, Status schreiben & reboot
on_error() {
  local rc=$?
  log "❌ Fehler/Abort im runner (rc=${rc})"
  # wenn Shared gemountet ist, Status schreiben
  if mountpoint -q "$SHARED_DIR"; then
    write_status "failed" "$rc" "runner_error"
  fi
  final_reboot
}
trap on_error ERR

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
  log "ℹ Kein Backup-Job gefunden – reboot zurück."
  write_status "skipped" 0 "no_job"
  final_reboot
fi

state="$(head -n1 "$FLAG_FILE" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
if [[ "$state" != "pending" && "$state" != "running" ]]; then
  log "ℹ Flag state=${state} → nicht startbar."
  exit 0
fi

log "✅ Backup-Job gefunden, lade ENV aus ${REQ_FILE}..."

# 3) ENV laden und exportieren
set -a
# shellcheck source=/dev/null
source "$REQ_FILE"
set +a

export MARKER_DIR="$SHARED_DIR"

MODE="${MODE:-no-health}"
ZERO_FILL="${ZERO_FILL:-false}"
HEALTH_CHECK="${HEALTH_CHECK:-false}"
BOS_MAINTANCE="${BOS_MAINTANCE:-false}"
BOS_UPDATE="${BOS_UPDATE:-false}"   # <-- NEU

# ============================================================
# Spezial-Modi
#   - BOS_MAINTANCE=true : im Backup-OS bleiben (exit 1), KEIN reboot
#   - BOS_UPDATE=true    : apt update/upgrade + reboot zurück
# ============================================================

if "$BOS_UPDATE"; then
  log "BOS_UPDATE=true → führe apt update/upgrade aus und reboote zurück"

  UPDATE_LOG="$SHARED_DIR/bos_update.log"
  {
    echo "===== $(date -Is) :: BOS_UPDATE START ====="
    echo "+ apt-get update"
    apt-get update
    echo "+ apt-get -y upgrade"
    DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
    echo "+ apt-get -y autoremove"
    DEBIAN_FRONTEND=noninteractive apt-get -y autoremove
    echo "+ apt-get clean"
    apt-get clean
    echo "===== $(date -Is) :: BOS_UPDATE DONE ====="
  } |& tee -a "$UPDATE_LOG"

  write_status "updated" 0 "update_done"
  final_reboot
fi

if "$BOS_MAINTANCE"; then
  log "BOS_MAINTANCE=true → Maintenance Mode: bleibe im Backup-OS (exit 1), KEIN reboot"
  write_status "maintenance" 1 "maintenance_mode"
  exit 1
fi

log "Job-Parameter: MODE=${MODE}, ZERO_FILL=${ZERO_FILL}, HEALTH_CHECK=${HEALTH_CHECK}"
log "Backup-Script: ${BACKUP_SCRIPT}"

if [[ ! -x "$BACKUP_SCRIPT" ]]; then
  log "❌ Backup-Script nicht ausführbar."
  write_status "failed" 127 "backup_script_missing"
  final_reboot
fi

# 4) Backup ausführen
BACKUP_EXIT=0
if ! "$BACKUP_SCRIPT"; then
  BACKUP_EXIT=$?
fi

STATE="success"
REASON="ok"
case "$BACKUP_EXIT" in
  0)  STATE="success";   REASON="ok" ;;
  10) STATE="unhealthy"; REASON="healthcheck_failed" ;;
  *)  STATE="failed";    REASON="backup_failed" ;;
esac

log "Backup abgeschlossen: STATE=${STATE}, EXIT=${BACKUP_EXIT}"
write_status "$STATE" "$BACKUP_EXIT" "$REASON"

# 5) Reboot zurück
final_reboot
