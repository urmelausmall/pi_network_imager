#!/usr/bin/env bash
set -euo pipefail

START_TS="$(date +%s)"

# =========================
# Konfiguration / Defaults
# =========================

# Wo das Image hin soll
BACKUP_DIR="${BACKUP_DIR:-/mnt/syno-backup}"

IMAGE_PREFIX="${IMAGE_PREFIX:-raspi-4gb-}"
RETENTION_COUNT="${RETENTION_COUNT:-3}"

# CIFS-Share für die Images
CIFS_SHARE="${CIFS_SHARE:-//192.168.178.25/System_Backup}"
CIFS_USER="${CIFS_USER:-User}"
CIFS_DOMAIN="${CIFS_DOMAIN:-WORKGROUP}"
CIFS_PASS="${CIFS_PASS:-}"
CIFS_UID="${CIFS_UID:-1000}"
CIFS_GID="${CIFS_GID:-1000}"

# Shared/Marker-Dir (für Logs + last_run)
MARKER_DIR="${MARKER_DIR:-/backupos_shared}"

# Gotify
GOTIFY_URL="${GOTIFY_URL:-}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"
GOTIFY_ENABLED="${GOTIFY_ENABLED:-true}"

# MQTT
MQTT_ENABLED="${MQTT_ENABLED:-false}"
MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
MQTT_TLS="${MQTT_TLS:-false}"
MQTT_DISCOVERY_PREFIX="${MQTT_DISCOVERY_PREFIX:-homeassistant}"
MQTT_TOPIC_PREFIX="${MQTT_TOPIC_PREFIX:-homelab/pi-backup}"

# Node-Name für MQTT / HA
if [[ -n "${BACKUP_NODE_NAME:-}" ]]; then
  NODE_NAME="$BACKUP_NODE_NAME"
else
  NODE_NAME="$(hostname)"
fi

# Mode / Flags kommen aus ENV (vom Runner gesetzt)
MODE="${MODE:-no-health}"       # dry-run | no-health | with-health
ZERO_FILL="${ZERO_FILL:-false}" # im Backup-OS erstmal deaktiviert (siehe unten)
HEALTH_CHECK="${HEALTH_CHECK:-false}"

DRY_RUN=false
case "$MODE" in
  dry-run)
    DRY_RUN=true
    HEALTH_CHECK=false
    ;;
  no-health)
    DRY_RUN=false
    HEALTH_CHECK=false
    ;;
  with-health)
    DRY_RUN=false
    HEALTH_CHECK=true
    ;;
esac

# Quelle unbedingt per Hint definieren:
BACKUP_SRC_HINT="${BACKUP_SRC_HINT:-}"

# Status-Flags
BACKUP_SUCCESS=false
HEALTHCHECK_OK=true     # default true
SAFE_TO_ROTATE=true

IMAGE_PATH=""
TOTAL_BYTES=0

# Logging
LOG_FILE=""
if [[ -d "$MARKER_DIR" ]]; then
  LOG_FILE="$MARKER_DIR/backup_sd.log"
fi

log() {
  local msg="[$(date '+%F %T')] [backup] $*"
  echo "$msg"
  if [[ -n "$LOG_FILE" ]]; then
    echo "$msg" >> "$LOG_FILE"
  fi
}

rotate_log() {
  [[ -n "$LOG_FILE" ]] || return 0
  [[ -f "$LOG_FILE" ]] || return 0
  local keep=10

  [[ -f "${LOG_FILE}.${keep}" ]] && rm -f "${LOG_FILE}.${keep}"
  for ((i=keep-1; i>=1; i--)); do
    [[ -f "${LOG_FILE}.${i}" ]] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
  done
  mv -f "$LOG_FILE" "${LOG_FILE}.1"
}

rotate_log

# =========================
# Hilfsfunktionen
# =========================

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

notify_gotify() {
  local title="$1"
  local message="$2"
  local priority="${3:-5}"

  if [[ "$GOTIFY_ENABLED" != true ]]; then
    return 0
  fi
  if [[ -z "$GOTIFY_URL" || -z "$GOTIFY_TOKEN" ]]; then
    return 0
  fi

  curl -sS -X POST "${GOTIFY_URL%/}/message?token=${GOTIFY_TOKEN}" \
    -F "title=${title}" \
    -F "message=${message}" \
    -F "priority=${priority}" \
    >/dev/null || true
}

mqtt_build_args() {
  local args=(-h "$MQTT_HOST" -p "$MQTT_PORT")
  if [[ -n "$MQTT_USER" ]]; then
    args+=( -u "$MQTT_USER" )
  fi
  if [[ -n "$MQTT_PASS" ]]; then
    args+=( -P "$MQTT_PASS" )
  fi
  if [[ "${MQTT_TLS,,}" == "true" ]]; then
    args+=( --tls-version tlsv1.2 )
  fi
  printf '%s\n' "${args[@]}"
}

mqtt_publish_retained() {
  local subtopic="$1"
  local payload="$2"

  [[ "$MQTT_ENABLED" == true ]] || return 0
  command -v mosquitto_pub >/dev/null 2>&1 || return 0

  local topic="${MQTT_TOPIC_PREFIX}/${NODE_NAME}/${subtopic}"
  mapfile -t base_args < <(mqtt_build_args)

  mosquitto_pub "${base_args[@]}" -t "$topic" -m "$payload" -r >/dev/null 2>&1 || true
}

choose_compressor() {
  if command -v pigz &>/dev/null; then
    log "🚀 pigz gefunden – nutze Multi-Core-Kompression."
    echo "pigz"
    return
  fi
  if command -v gzip &>/dev/null; then
    log "ℹ️ pigz nicht gefunden – nutze gzip."
    echo "gzip"
    return
  fi
  log "❌ Weder pigz noch gzip gefunden."
  exit 1
}

resolve_backup_device() {
  if [[ -z "$BACKUP_SRC_HINT" ]]; then
    log "❌ BACKUP_SRC_HINT ist nicht gesetzt – ich weiß nicht, welches Device gesichert werden soll."
    log "   Erwarte z.B.: BACKUP_SRC_HINT=DEVICE=/dev/sda oder LABEL=RASPI_ROOT oder PARTUUID=xxxx-xxxx"
    exit 1
  fi

  local hint="$BACKUP_SRC_HINT"
  local dev=""

  case "$hint" in
    DEVICE=/dev/*)
      dev="${hint#DEVICE=}"
      ;;
    LABEL=*)
      local lbl="${hint#LABEL=}"
      dev="$(blkid -L "$lbl" 2>/dev/null || true)"
      if [[ -z "$dev" ]]; then
        log "❌ Kein Device mit LABEL=${lbl} gefunden."
        exit 1
      fi
      ;;
    PARTUUID=*)
      local pu="${hint#PARTUUID=}"
      dev="$(blkid -t "PARTUUID=${pu}" -o device 2>/dev/null | head -n1 || true)"
      if [[ -z "$dev" ]]; then
        log "❌ Kein Device mit PARTUUID=${pu} gefunden."
        exit 1
      fi
      ;;
    *)
      log "❌ Unbekanntes BACKUP_SRC_HINT-Format: ${hint}"
      exit 1
      ;;
  esac

  # Wenn wir eine Partition erwischt haben (/dev/sda2, /dev/mmcblk0p2), auf das ganze Device gehen.
  local base="$dev"
  if [[ "$dev" == /dev/mmcblk* ]]; then
    base="${dev%%p[0-9]*}"
  else
    base="${dev%%[0-9]*}"
  fi

  if [[ -z "$base" || ! -b "$base" ]]; then
    log "❌ Abgeleitetes Device ${base} ist kein Block-Device."
    exit 1
  fi

  DEV="$base"
  log "💾 Sicherungsquelle: ${DEV} (aus Hint: ${BACKUP_SRC_HINT})"
}

compute_total_bytes() {
  local d="$DEV"
  TOTAL_BYTES=0

  if command -v blockdev &>/dev/null; then
    TOTAL_BYTES="$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)"
  fi
  if [[ "$TOTAL_BYTES" -eq 0 ]] && command -v lsblk &>/dev/null; then
    TOTAL_BYTES="$(lsblk -nbdo SIZE "$d" 2>/dev/null | head -n1 || echo 0)"
  fi
  if [[ "$TOTAL_BYTES" -eq 0 && -r "/sys/block/$(basename "$d")/size" ]]; then
    local sec
    sec="$(cat "/sys/block/$(basename "$d")/size" 2>/dev/null || echo 0)"
    TOTAL_BYTES=$((sec * 512))
  fi

  log "DEBUG: TOTAL_BYTES für ${d} = ${TOTAL_BYTES}"
}

rotate_backups() {
  local pattern="$BACKUP_DIR/${IMAGE_PREFIX}"*.img.gz

  shopt -s nullglob
  local files=( $pattern )
  shopt -u nullglob

  local total=${#files[@]}
  if (( total <= RETENTION_COUNT )); then
    log "🧹 Retention: ${total} Backups gefunden, nichts zu löschen (Limit: ${RETENTION_COUNT})."
    return 0
  fi

  IFS=$'\n' files=($(printf '%s\n' "${files[@]}" | sort))
  unset IFS

  local to_delete_count=$(( total - RETENTION_COUNT ))
  local delete_list=( "${files[@]:0:to_delete_count}" )

  log "🧹 Retention aktiv: Behalte die letzten ${RETENTION_COUNT} Backups, lösche ${#delete_list[@]} ältere:"
  for f in "${delete_list[@]}"; do
    log "   → Lösche $f"
    rm -f -- "$f"
  done
}

rename_image_on_exit() {
  # Nur wenn es überhaupt eine Zieldatei gibt
  [[ -n "$IMAGE_PATH" ]] || return 0
  [[ -f "$IMAGE_PATH" ]] || return 0

  # Erfolg + Health OK → nix tun
  if $BACKUP_SUCCESS && $HEALTHCHECK_OK; then
    return 0
  fi

  local ts base new_path
  ts="$(date +%F_%H%M%S)"
  base="${IMAGE_PATH%.img.gz}"

  if ! $BACKUP_SUCCESS; then
    new_path="${base}.FAILED_${ts}.img.gz"
  else
    new_path="${base}.UNHEALTHY_${ts}.img.gz"
  fi

  # Mehrfaches Umbenennen vermeiden
  if [[ "$IMAGE_PATH" == *".FAILED_"*".img.gz" || "$IMAGE_PATH" == *".UNHEALTHY_"*".img.gz" ]]; then
    return 0
  fi

  log "⚠️ Backup nicht sauber – benenne Image um: $(basename "$IMAGE_PATH") → $(basename "$new_path")"
  mv -f -- "$IMAGE_PATH" "$new_path" || log "❌ Umbenennen fehlgeschlagen."
}

on_exit() {
  local exit_code=$?
  # Wenn Script hart mit Fehler rausfliegt → Rename auslösen
  if (( exit_code != 0 )); then
    SAFE_TO_ROTATE=false
  fi
  rename_image_on_exit
}
trap on_exit EXIT

# =========================
# Start-Infos / Checks
# =========================

END_HUMAN=""
DURATION_STR=""

ZIP_CMD="$(choose_compressor)"

if ! command -v dd &>/dev/null; then
  log "❌ dd nicht gefunden."
  exit 1
fi

if ! command -v mount.cifs &>/dev/null; then
  log "❌ cifs-utils / mount.cifs nicht vorhanden."
  exit 1
fi

if [[ "$ZERO_FILL" == "true" ]]; then
  log "ℹ️ Hinweis: ZERO_FILL im Backup-OS ist momentan deaktiviert (Quelle ist nicht gemountet)."
  log "   Wenn du das brauchst, müssen wir die Root-Partition der Quellplatte im Backup-OS mounten und dort ein Zero-File schreiben."
fi

resolve_backup_device
compute_total_bytes

DATE_STR="$(date +%F_%H%M)"
IMAGE_NAME="${IMAGE_PREFIX}${DATE_STR}.img.gz"
IMAGE_PATH="${BACKUP_DIR}/${IMAGE_NAME}"

MODE_TEXT="Normal"
$DRY_RUN && MODE_TEXT="Dry-Run"
$HEALTH_CHECK && MODE_TEXT="${MODE_TEXT} + Healthcheck"

log "==== Backup startet ===="
log "Modus: ${MODE_TEXT}"
log "Ziel-Datei: ${IMAGE_PATH}"

notify_gotify "Backup startet (${NODE_NAME})" \
  "Modus: ${MODE_TEXT}
Quelle: ${BACKUP_SRC_HINT}
Ziel: ${CIFS_SHARE}/${IMAGE_NAME}" \
  4

mqtt_publish_retained "status" "$(printf '{"phase":"starting","mode":"%s"}' "$MODE_TEXT")"

# =========================
# CIFS-Mount
# =========================

mkdir -p "$BACKUP_DIR"

if ! mountpoint -q "$BACKUP_DIR"; then
  log "[0/4] Mounten der CIFS-Freigabe..."
  if [[ -z "$CIFS_PASS" ]]; then
    log "❌ CIFS_PASS ist nicht gesetzt."
    exit 1
  fi

  opts="username=${CIFS_USER},password=${CIFS_PASS},domain=${CIFS_DOMAIN},uid=${CIFS_UID},gid=${CIFS_GID},iocharset=utf8,vers=3.0,_netdev"
  if ! mount -t cifs "$CIFS_SHARE" "$BACKUP_DIR" -o "$opts"; then
    log "❌ CIFS-Share konnte NICHT gemountet werden: ${CIFS_SHARE}"
    exit 1
  fi
else
  log "[0/4] CIFS-Share bereits gemountet."
fi


# =========================
# Backup (dd + pigz)
# =========================

if $DRY_RUN; then
  log "[1/4] 🧪 Dry-Run – es wird NICHT wirklich geschrieben."
  mqtt_publish_retained "status" "$(printf '{"phase":"dd_start","mode":"%s","dry_run":true}' "$MODE_TEXT")"

  [[ "$TOTAL_BYTES" -eq 0 ]] && TOTAL_BYTES=100
  for p in 0 25 50 75 100; do
    mqtt_publish_retained "progress" \
      "$(printf '{"phase":"dd_running","bytes":%s,"total":%s,"percent":%s}' \
          $((TOTAL_BYTES * p / 100)) "$TOTAL_BYTES" "$p")"
    sleep 1
  done

  mqtt_publish_retained "progress" \
    "$(printf '{"phase":"dd_done","bytes":%s,"total":%s,"percent":100}' "$TOTAL_BYTES" "$TOTAL_BYTES")"

  mqtt_publish_retained "status" \
    "$(printf '{"phase":"dd_done","mode":"%s","dry_run":true}' "$MODE_TEXT")"

  BACKUP_SUCCESS=true
else
  log "[1/4] Erstelle Image von ${DEV} → ${IMAGE_PATH}"

  mqtt_publish_retained "status" "$(printf '{"phase":"dd_start","mode":"%s"}' "$MODE_TEXT")"
  mqtt_publish_retained "progress" "$(printf '{"phase":"dd_start","bytes":0,"total":%s,"percent":0}' "$TOTAL_BYTES")"

  set +e
  dd if="$DEV" bs=4M status=progress | "$ZIP_CMD" > "$IMAGE_PATH"
  DD_EXIT=$?
  set -e

  if (( DD_EXIT != 0 )); then
    log "❌ dd/${ZIP_CMD} Exit-Code: ${DD_EXIT}"
    mqtt_publish_retained "status" "$(printf '{"phase":"error","mode":"%s","dd_exit":%d}' "$MODE_TEXT" "$DD_EXIT")"
    BACKUP_SUCCESS=false
    exit 2
  fi

  sync
  mqtt_publish_retained "progress" "$(printf '{"phase":"dd_done","bytes":%s,"total":%s,"percent":100}' "$TOTAL_BYTES" "$TOTAL_BYTES")"
  mqtt_publish_retained "status" "$(printf '{"phase":"dd_done","mode":"%s"}' "$MODE_TEXT")"
  BACKUP_SUCCESS=true
fi

# =========================
# Healthcheck + Rotation
# =========================

if ! $DRY_RUN && $HEALTH_CHECK; then
  log "[2/4] Healthcheck des Archivs..."
  if "$ZIP_CMD" -t "$IMAGE_PATH"; then
    log "✅ Healthcheck OK."
    HEALTHCHECK_OK=true
  else
    log "❌ Healthcheck fehlgeschlagen – Archiv könnte korrupt sein."
    HEALTHCHECK_OK=false
    SAFE_TO_ROTATE=false
    notify_gotify "Backup Healthcheck FEHLER (${NODE_NAME})" \
      "Healthcheck für ${CIFS_SHARE}/${IMAGE_NAME} ist fehlgeschlagen." \
      7
    # Exit-Code 10 → Runner markiert als “unhealthy”
    exit 10
  fi
else
  log "[2/4] Healthcheck ist deaktiviert."
  HEALTHCHECK_OK=true
fi

if ! $DRY_RUN; then
  if $BACKUP_SUCCESS && $SAFE_TO_ROTATE && $HEALTHCHECK_OK; then
    log "[3/4] Rotation der alten Backups..."
    rotate_backups
  else
    log "[3/4] Rotation übersprungen (BACKUP_SUCCESS=${BACKUP_SUCCESS}, SAFE_TO_ROTATE=${SAFE_TO_ROTATE}, HEALTHCHECK_OK=${HEALTHCHECK_OK})"
  fi
else
  log "[3/4] Rotation übersprungen (Dry-Run)."
fi

# =========================
# Unmount + Abschluss
# =========================

log "[4/4] Unmount CIFS..."
umount "$BACKUP_DIR" || log "⚠️ Unmount fehlgeschlagen/bereits unmounted."

END_TS="$(date +%s)"
DURATION_SEC=$(( END_TS - START_TS ))
DURATION_STR="$(format_duration "$DURATION_SEC")"
END_HUMAN="$(date '+%d.%m.%Y %H:%M')"

MODE_TEXT="Normal"
$DRY_RUN && MODE_TEXT="Dry-Run"
$HEALTH_CHECK && MODE_TEXT="${MODE_TEXT} + Healthcheck"

log "✅ Backup abgeschlossen."
log "Dauer: ${DURATION_STR}"
log "Fertiggestellt: ${END_HUMAN}"
log "Datei: ${CIFS_SHARE}/${IMAGE_NAME}"

# last_run.json ins MARKER_DIR schreiben (kann Haupt-OS später lesen)
if [[ -d "$MARKER_DIR" ]]; then
  cat > "$MARKER_DIR/last_run.json" <<EOF
{"finished_at":"$END_HUMAN","duration":"$DURATION_STR","seconds":$DURATION_SEC,"mode":"$MODE_TEXT","image":"$IMAGE_NAME","state":"success"}
EOF
fi

mqtt_publish_retained "status" \
  "$(printf '{"phase":"success","mode":"%s","dry_run":%s,"duration":"%s","finished_at":"%s"}' \
    "$MODE_TEXT" "$DRY_RUN" "$DURATION_STR" "$END_HUMAN")"

notify_gotify "Backup erfolgreich (${NODE_NAME})" \
  "Modus: ${MODE_TEXT}
Dauer: ${DURATION_STR}
Fertiggestellt: ${END_HUMAN}
Datei: ${CIFS_SHARE}/${IMAGE_NAME}" \
  5

exit 0