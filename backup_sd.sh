#!/usr/bin/env bash
set -euo pipefail

START_TS="$(date +%s)"

# =========================
# Konfiguration / Defaults
# =========================

# Verhalten / Optionen
DRY_RUN=false
DRY_RUN_FROM_CLI=false
HEALTH_CHECK=false
HEALTH_CHECK_FROM_CLI=false
NON_INTERACTIVE=false

ZERO_FILL="${ZERO_FILL:-false}"     # optionales Zero-Fill des freien Platzes

# Debug / optional Docker-Handling
SKIP_DOCKER_STOP="${SKIP_DOCKER_STOP:-false}"
SKIP_DOCKER_START="${SKIP_DOCKER_START:-false}"

# Per ENV überschreibbar
START_DELAY="${START_DELAY:-15}"                 # Sekunden vor Start von NPM Plus
IMAGE_PREFIX="${IMAGE_PREFIX:-raspi-4gb-}"       # Standard-Präfix für Backupdatei
RETENTION_COUNT="${RETENTION_COUNT:-2}"          # inkl. aktuellem Backup

# Pfade / Shares (per ENV anpassbar)
BACKUP_DIR="${BACKUP_DIR:-/mnt/syno-backup}"
CIFS_SHARE="${CIFS_SHARE:-//192.168.178.25/System_Backup}"
MARKER_DIR="${MARKER_DIR:-/markers}"
DOCKER_BOOT_SCRIPT="${DOCKER_BOOT_SCRIPT:-/app/docker-boot-start.sh}"

# CIFS Auth – portabel konfigurierbar
CIFS_USER="${CIFS_USER:-User}"       # Standard-User, per ENV/CLI änderbar
CIFS_DOMAIN="${CIFS_DOMAIN:-WORKGROUP}"
CIFS_PASS="${CIFS_PASS:-}"           # lieber über ENV setzen statt im Script
CIFS_UID="${CIFS_UID:-1000}"
CIFS_GID="${CIFS_GID:-1000}"

# Gotify Defaults (per ENV überschreibbar)
GOTIFY_URL="${GOTIFY_URL:-http://192.168.178.25:6742}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-xxxxxxxx}"
GOTIFY_ENABLED="${GOTIFY_ENABLED:-true}"

# MQTT Defaults (per ENV überschreibbar)
MQTT_ENABLED="${MQTT_ENABLED:-false}"
MQTT_HOST="${MQTT_HOST:-192.168.178.25}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
MQTT_TLS="${MQTT_TLS:-false}"
MQTT_DISCOVERY_PREFIX="${MQTT_DISCOVERY_PREFIX:-homeassistant}"
MQTT_TOPIC_PREFIX="${MQTT_TOPIC_PREFIX:-homelab/pi-backup}"

# Friendly Name / Node-Name für MQTT & HA
BACKUP_NODE_NAME="${BACKUP_NODE_NAME:-}"

# Status-Flags für sichere Rotation
BACKUP_SUCCESS=false
SAFE_TO_ROTATE=true
HEALTHCHECK_OK=false

# Logging ins MARKER_DIR (falls vorhanden)
LOG_FILE=""
if [[ -d "$MARKER_DIR" ]]; then
  LOG_FILE="$MARKER_DIR/backup_sd.log"
fi

rotate_log() {
  [[ -n "${LOG_FILE:-}" ]] || return 0
  [[ -f "$LOG_FILE" ]] || return 0

  local keep=10

  # älteste weg
  [[ -f "${LOG_FILE}.${keep}" ]] && rm -f "${LOG_FILE}.${keep}"

  # durchschieben
  for ((i=keep-1; i>=1; i--)); do
    [[ -f "${LOG_FILE}.${i}" ]] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
  done

  # aktuelles zu .1
  mv -f "$LOG_FILE" "${LOG_FILE}.1"
}

rotate_log

log_msg() {
  local msg="[$(date '+%F %T')] $*"
  # immer auf STDOUT (damit es in docker logs auftaucht)
  echo "$msg"
  # optional zusätzlich in Datei
  if [[ -n "$LOG_FILE" ]]; then
    echo "$msg" >> "$LOG_FILE"
  fi
}

# =========================
# Funktionen
# =========================

# Globaler Node-Name (für MQTT & HA-Discovery)
if [[ -n "$BACKUP_NODE_NAME" ]]; then
  NODE_NAME="$BACKUP_NODE_NAME"
else
  NODE_NAME="$(hostname)"
fi

LAST_RUN_FILE=""
LAST_RUN_INFO=""
if [[ -d "$MARKER_DIR" ]]; then
  LAST_RUN_FILE="$MARKER_DIR/last_run.json"
  if [[ -r "$LAST_RUN_FILE" ]]; then
    LAST_RUN_INFO="$(cat "$LAST_RUN_FILE" 2>/dev/null || true)"
  fi
fi

dd_progress_reader() {
  local last_percent=-1
  local line trimmed raw bytes percent

  while IFS= read -r line; do
    # Leading Whitespace entfernen
    trimmed="${line#"${line%%[![:space:]]*}"}"

    # Beispiel-Zeilen (deutsches Locale):
    # "1.048.576 bytes (1,0 MB, 1,0 MiB) copied, ..."
    # "128.450.560 bytes (128 MB, 122 MiB) copied, ..."
    if [[ "$trimmed" =~ ^([0-9][0-9.,]*)\ bytes ]]; then
      raw="${BASH_REMATCH[1]}"

      # alle Trenner raus: "1.048.576" -> "1048576", "1,048,576" -> "1048576"
      bytes="${raw//[.,]/}"

      if (( TOTAL_BYTES > 0 )); then
        percent=$(( bytes * 100 / TOTAL_BYTES ))
      else
        percent=0
      fi

      if (( percent != last_percent )); then
        log_msg "DD Progress: ${percent}% (${bytes}/${TOTAL_BYTES} Bytes)"
        last_percent=$percent
      fi

      mqtt_publish_retained "progress" "$(printf '{"phase":"dd_running","bytes":%s,"total":%s,"percent":%s}' "$bytes" "$TOTAL_BYTES" "$percent")"
    fi
  done
}


usage() {
  cat <<'USAGE'
Usage: backup_sd.sh [OPTIONEN]

Optionen:
  --dry-run,       -n          Überspringt NUR den Backup-Schritt (dd|gzip).
  --no-dry-run                Erzwingt echten Lauf ohne Rückfrage.
  --delay,        -d <sek>    Wartezeit in Sekunden vor NPM Plus Start (Default: 15).
  --prefix,       -p <name>   Präfix für den Backupdateinamen (z.B. "raspi-8gb-").
  --keep,         -k <anzahl> Anzahl der zu behaltenden Backups (inkl. aktuellem), Default: 3.
  --health-check              Healthcheck des Backups am Ende erzwingen.
  --no-health-check           Healthcheck am Ende deaktivieren.
  --non-interactive, -y       Keine Rückfragen: kein Dry-Run, mit Healthcheck, Standard-Präfix.

  --cifs-user <user>          CIFS Benutzername (override von $CIFS_USER).
  --cifs-pass <pass>          CIFS Passwort (unsicher, besser ENV oder Prompt).
  --cifs-domain <domain>      CIFS Domain/Workgroup (override von $CIFS_DOMAIN).

  --help,         -h          Diese Hilfe.

Ohne --dry-run/--no-dry-run wird interaktiv gefragt.
Ohne --health-check/--no-health-check wird interaktiv gefragt.
USAGE
}

run_as_root() {
  # Wenn wir bereits root sind (z.B. im Container) → direkt ausführen
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
    return
  fi

  # Sonst sudo verwenden, falls vorhanden
  if command -v sudo &>/dev/null; then
    sudo "$@"
  else
    "$@"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"  # J oder N
  local answer

  case "$default" in
    J|j) prompt+=" [J/n] " ;;
    N|n|*) prompt+=" [j/N] " ;;
  esac

  read -r -p "$prompt" answer || answer=""
  answer="${answer:-$default}"

  case "${answer}" in
    J|j|Y|y) return 0 ;;
    *)       return 1 ;;
  esac
}

# curl-Checker mit Install-Option
ensure_curl() {
  if command -v curl &>/dev/null; then
    return 0
  fi

  log_msg "❌ 'curl' wurde nicht gefunden, wird aber für Gotify-Notifications benötigt." >&2

  if $NON_INTERACTIVE; then
    log_msg "Versuche automatische Installation von 'curl'..." >&2
    if run_as_root apt-get update && run_as_root apt-get install -y curl; then
      log_msg "✅ curl installiert." >&2
      return 0
    else
      log_msg "❌ Installation von curl fehlgeschlagen. Es werden keine Gotify-Notifications gesendet." >&2
      return 1
    fi
  else
    if ask_yes_no "curl installieren? (für Gotify-Notifications benötigt)" "J"; then
      if run_as_root apt-get update && run_as_root apt-get install -y curl; then
        log_msg "✅ curl installiert." >&2
        return 0
      else
        log_msg "❌ Installation von curl fehlgeschlagen. Es werden keine Gotify-Notifications gesendet." >&2
        return 1
      fi
    else
      log_msg "ℹ️ Ohne curl werden keine Gotify-Notifications gesendet." >&2
      return 1
    fi
  fi
}

notify_gotify() {
  local title="$1"
  local message="$2"
  local priority="${3:-5}"

  if [[ "$GOTIFY_ENABLED" != true ]]; then
    return 0
  fi

  if [[ -z "${GOTIFY_URL:-}" || -z "${GOTIFY_TOKEN:-}" ]]; then
    return 0
  fi

  if ! ensure_curl; then
    return 0
  fi

  curl -sS -X POST "${GOTIFY_URL%/}/message?token=${GOTIFY_TOKEN}" \
    -F "title=${title}" \
    -F "message=${message}" \
    -F "priority=${priority}" \
    >/dev/null || true
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

zero_free_space() {
  log_msg "🧹 Zero-Fill: Freien Speicher mit Nullen füllen für bessere Kompression..."

  # Verfügbare Bytes im Root-FS ermitteln
  local avail_bytes
  avail_bytes="$(df --output=avail -B1 / | sed -n '2p' | tr -d ' ' || echo 0)"

  if [[ -z "$avail_bytes" || "$avail_bytes" -le 0 ]]; then
    log_msg "⚠️ Konnte freien Speicher nicht ermitteln – überspringe Zero-Fill."
    return 0
  fi

  # First try: fallocate (wenn unterstützt, ist das sehr schnell)
  if command -v fallocate &>/dev/null; then
    if fallocate -l "$avail_bytes" /zero.fill 2>/dev/null; then
      log_msg "⚡ Zero-Fill via fallocate erfolgreich."
    else
      log_msg "ℹ️ fallocate nicht geeignet – falle auf dd zurück..."
      dd if=/dev/zero of=/zero.fill bs=1M || true
    fi
  else
    log_msg "ℹ️ fallocate nicht vorhanden – nutze dd für Zero-Fill..."
    dd if=/dev/zero of=/zero.fill bs=1M || true
  fi

  sync
  rm -f /zero.fill || true
  sync
  log_msg "✅ Zero-Fill abgeschlossen."
}


choose_compressor() {
  local zip_cmd=""

  if command -v pigz &> /dev/null; then
    # Nur Info nach STDERR, damit es NICHT in ZIP_CMD landet
    echo "🚀 pigz gefunden! Nutze Multi-Core-Kompression." >&2
    echo "pigz"
    return
  fi

  echo "⚠️  pigz nicht gefunden." >&2

  if ! $NON_INTERACTIVE && ask_yes_no "pigz installieren? (empfohlen für schnellere Backups)" "J"; then
    if run_as_root apt-get update && run_as_root apt-get install -y pigz; then
      echo "✅ pigz installiert." >&2
      echo "pigz"
      return
    else
      echo "❌ Installation von pigz fehlgeschlagen." >&2
    fi
  fi

  # Fallback: gzip
  if command -v gzip &> /dev/null; then
    echo "ℹ️  Nutze gzip als Fallback." >&2
    echo "gzip"
    return
  fi

  echo "⚠️  Weder pigz noch gzip gefunden." >&2
  if ! $NON_INTERACTIVE && ask_yes_no "gzip installieren?" "J"; then
    if run_as_root apt-get update && run_as_root apt-get install -y gzip; then
      echo "✅ gzip installiert." >&2
      echo "gzip"
      return
    else
      echo "❌ Installation von gzip fehlgeschlagen." >&2
      echo "❌ Kein Kompressor verfügbar. Breche ab." >&2
      exit 1
    fi
  else
    echo "❌ Kein Kompressor verfügbar. Breche ab." >&2
    exit 1
  fi
}


rotate_backups() {
  local pattern="$BACKUP_DIR/${IMAGE_PREFIX}"*.img.gz

  shopt -s nullglob
  # shellcheck disable=SC2206
  local files=( $pattern )
  shopt -u nullglob

  local total=${#files[@]}
  if (( total <= RETENTION_COUNT )); then
    log_msg "🧹 Retention: ${total} Backups gefunden, nichts zu löschen (Limit: ${RETENTION_COUNT})."
    return 0
  fi

  IFS=$'\n' files=($(printf '%s\n' "${files[@]}" | sort))
  unset IFS

  local to_delete_count=$(( total - RETENTION_COUNT ))
  local delete_list=( "${files[@]:0:to_delete_count}" )

  log_msg "🧹 Retention aktiv: Behalte die letzten ${RETENTION_COUNT} Backups, lösche ${#delete_list[@]} ältere:"
  for f in "${delete_list[@]}"; do
    log_msg "   → Lösche $f"
    rm -f -- "$f"
  done
}

ensure_cifs_utils() {
  if command -v mount.cifs &>/dev/null; then
    return 0
  fi

  log_msg "❌ CIFS-Tools ('cifs-utils') wurden nicht gefunden." >&2

  if $NON_INTERACTIVE; then
    log_msg "Versuche automatische Installation von 'cifs-utils'..." >&2
    if run_as_root apt-get update && run_as_root apt-get install -y cifs-utils; then
      log_msg "✅ cifs-utils installiert." >&2
      return 0
    else
      log_msg "❌ Installation von cifs-utils fehlgeschlagen. Breche ab." >&2
      exit 1
    fi
  else
    if ask_yes_no "cifs-utils installieren? (für CIFS-Mount benötigt)" "J"; then
      if run_as_root apt-get update && run_as_root apt-get install -y cifs-utils; then
        log_msg "✅ cifs-utils installiert." >&2
        return 0
      else
        log_msg "❌ Installation von cifs-utils fehlgeschlagen. Breche ab." >&2
        exit 1
      fi
    else
      log_msg "❌ Ohne cifs-utils kein CIFS-Mount möglich. Breche ab." >&2
      exit 1
    fi
  fi
}

ensure_mqtt_cli() {
  if [[ "$MQTT_ENABLED" != true ]]; then
    return 1
  fi

  if command -v mosquitto_pub &>/dev/null; then
    return 0
  fi

  log_msg "ℹ️ MQTT aktiviert, aber 'mosquitto_pub' nicht gefunden." >&2

  if $NON_INTERACTIVE; then
    log_msg "Versuche automatische Installation von 'mosquitto-clients'..." >&2
    if run_as_root apt-get update && run_as_root apt-get install -y mosquitto-clients; then
      log_msg "✅ mosquitto-clients installiert." >&2
      return 0
    else
      log_msg "❌ Installation von mosquitto-clients fehlgeschlagen. MQTT-Updates werden deaktiviert." >&2
      MQTT_ENABLED=false
      return 1
    fi
  else
    if ask_yes_no "mosquitto-clients installieren? (für MQTT-Statusmeldungen)" "J"; then
      if run_as_root apt-get update && run_as_root apt-get install -y mosquitto-clients; then
        log_msg "✅ mosquitto-clients installiert." >&2
        return 0
      else
        log_msg "❌ Installation von mosquitto-clients fehlgeschlagen. MQTT-Updates werden deaktiviert." >&2
        MQTT_ENABLED=false
        return 1
      fi
    else
      log_msg "ℹ️ MQTT-Statusmeldungen deaktiviert (keine mosquitto-clients installiert)." >&2
      MQTT_ENABLED=false
      return 1
    fi
  fi
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

mqtt_publish() {
  local subtopic="$1"
  local payload="$2"

  [[ "$MQTT_ENABLED" == true ]] || return 0
  ensure_mqtt_cli || return 0

  local topic="${MQTT_TOPIC_PREFIX}/${NODE_NAME}/${subtopic}"

  mapfile -t base_args < <(mqtt_build_args)

  mosquitto_pub "${base_args[@]}" -t "$topic" -m "$payload" >/dev/null 2>&1 || true
}

mqtt_publish_retained() {
  local subtopic="$1"
  local payload="$2"

  [[ "$MQTT_ENABLED" == true ]] || return 0
  ensure_mqtt_cli || return 0

  local topic="${MQTT_TOPIC_PREFIX}/${NODE_NAME}/${subtopic}"
  mapfile -t base_args < <(mqtt_build_args)

  mosquitto_pub "${base_args[@]}" -t "$topic" -m "$payload" -r >/dev/null 2>&1 || true
}

mqtt_publish_config() {
  local topic="$1"
  local payload="$2"

  [[ "$MQTT_ENABLED" == true ]] || return 0
  ensure_mqtt_cli || return 0

  mapfile -t base_args < <(mqtt_build_args)

  # -r: retained, wichtig für HA Discovery
  mosquitto_pub "${base_args[@]}" -t "$topic" -m "$payload" -r >/dev/null 2>&1 || true
}

ensure_supported_system() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      raspbian|debian)
        ;;
      *)
        log_msg "⚠️ Achtung: System ist nicht als Raspberry Pi OS/Debian erkannt (ID='${ID:-unbekannt}')." >&2
        log_msg "   Script ist primär für Raspberry Pi OS / Debian gedacht." >&2
        ;;
    esac
  fi
}

on_error() {
  local exit_code=$?
  local end_ts
  end_ts="$(date +%s)"
  local dur=$(( end_ts - START_TS ))
  local dur_str
  dur_str="$(format_duration "$dur")"
  local end_human
  end_human="$(date '+%d.%m.%Y %H:%M')"

  log_msg "❌ Backup abgebrochen mit Exit-Code ${exit_code} nach ${dur_str}"

  mqtt_publish_retained "status" "$(printf '{"phase":"failure","mode":"%s","exit_code":%d}' "$MODE_TEXT" "$exit_code")"
  mqtt_publish_retained "progress" '{"phase":"failure","percent":0}' 

  notify_gotify "Backup FEHLGESCHLAGEN" \
    "Backup-Script auf ${IMAGE_PREFIX} ist mit Exit-Code ${exit_code} abgebrochen.
Fertiggestellt (Fehler): ${end_human} (${dur_str})." \
    8
}
trap 'on_error' ERR

# -------------------------
# Systemcheck ausführen
# -------------------------
# MQTT-CLI vorab prüfen, falls aktiviert (verhindert Ärger im dd-Loop)
if [[ "$MQTT_ENABLED" == true ]]; then
  ensure_mqtt_cli || MQTT_ENABLED=false
fi

ensure_supported_system

# =========================
# CLI Parsing
# =========================
while [[ "${1:-}" =~ ^- ]]; do
  case "$1" in
    --dry-run|-n)
      DRY_RUN=true
      DRY_RUN_FROM_CLI=true
      shift
      ;;
    --no-dry-run)
      DRY_RUN=false
      DRY_RUN_FROM_CLI=true
      shift
      ;;
    --zero-fill)
      ZERO_FILL=true
      shift
      ;;
    --delay|-d)
      shift
      [[ $# -gt 0 ]] || { log_msg "Fehlender Wert für --delay" >&2; exit 2; }
      START_DELAY="$1"; shift
      ;;
    --prefix|-p)
      shift
      [[ $# -gt 0 ]] || { log_msg "Fehlender Wert für --prefix" >&2; exit 2; }
      IMAGE_PREFIX="$1"
      shift
      ;;
    --keep|-k)
      shift
      [[ $# -gt 0 ]] || { log_msg "Fehlender Wert für --keep" >&2; exit 2; }
      RETENTION_COUNT="$1"
      shift
      ;;
    --health-check)
      HEALTH_CHECK=true
      HEALTH_CHECK_FROM_CLI=true
      shift
      ;;
    --no-health-check)
      HEALTH_CHECK=false
      HEALTH_CHECK_FROM_CLI=true
      shift
      ;;
    --non-interactive|-y)
      NON_INTERACTIVE=true
      DRY_RUN=false
      HEALTH_CHECK=true
      DRY_RUN_FROM_CLI=true
      HEALTH_CHECK_FROM_CLI=true
      shift
      ;;
    --cifs-user)
      shift
      [[ $# -gt 0 ]] || { log_msg "Fehlender Wert für --cifs-user" >&2; exit 2; }
      CIFS_USER="$1"
      shift
      ;;
    --cifs-pass)
      shift
      [[ $# -gt 0 ]] || { log_msg "Fehlender Wert für --cifs-pass" >&2; exit 2; }
      CIFS_PASS="$1"
      shift
      ;;
    --cifs-domain)
      shift
      [[ $# -gt 0 ]] || { log_msg "Fehlender Wert für --cifs-domain" >&2; exit 2; }
      CIFS_DOMAIN="$1"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      log_msg "Unbekannte Option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# =========================
# Interaktive Fragen (falls nötig)
# =========================

if ! $NON_INTERACTIVE; then
  if [[ "$DRY_RUN_FROM_CLI" == false ]]; then
    if ask_yes_no "Dry-Run ausführen (kein echtes dd-Backup)?" "N"; then
      DRY_RUN=true
    else
      DRY_RUN=false
    fi
  fi

  if [[ "$HEALTH_CHECK_FROM_CLI" == false ]]; then
    if ask_yes_no "Am Ende einen Healthcheck des Backups ausführen? (kann etwas dauern)" "J"; then
      HEALTH_CHECK=true
    else
      HEALTH_CHECK=false
    fi
  fi

  if ask_yes_no "Standard-Dateipräfix \"${IMAGE_PREFIX}\" verwenden?" "J"; then
    :
  else
    read -r -p "Neues Präfix (z.B. raspi-8gb-): " NEW_PREFIX
    if [[ -n "${NEW_PREFIX:-}" ]]; then
      IMAGE_PREFIX="$NEW_PREFIX"
    fi
  fi
fi

# =========================
# Dynamische Namen & MQTT Discovery
# =========================
DATE_STR="$(date +%F_%H%M)"
IMAGE_NAME="${IMAGE_PREFIX}${DATE_STR}.img.gz"
MODE_TEXT="Normal"
$DRY_RUN && MODE_TEXT="Dry-Run"
$HEALTH_CHECK && MODE_TEXT="${MODE_TEXT} + Healthcheck"

# Discovery-Konfigurationen
if [[ "$MQTT_ENABLED" == true ]]; then
  local_state_topic_status="${MQTT_TOPIC_PREFIX}/${NODE_NAME}/status"
  local_state_topic_progress="${MQTT_TOPIC_PREFIX}/${NODE_NAME}/progress"


  # Last-Run Sensor (zeigt finished_at als State + last_run als Attribute)
mqtt_publish_config \
  "${MQTT_DISCOVERY_PREFIX}/sensor/${NODE_NAME}_backup_last_run/config" \
  "$(cat <<EOF
{
  "name": "Backup letzter Lauf ${NODE_NAME}",
  "state_topic": "${MQTT_TOPIC_PREFIX}/${NODE_NAME}/status",
  "value_template": "{{ value_json.last_run.finished_at if value_json.last_run is defined else 'unbekannt' }}",
  "json_attributes_topic": "${MQTT_TOPIC_PREFIX}/${NODE_NAME}/status",
  "json_attributes_template": "{{ value_json.last_run | tojson if value_json.last_run is defined else '{}' }}",
  "unique_id": "${NODE_NAME}_backup_last_run",
  "object_id": "${NODE_NAME}_backup_last_run"
}
EOF
)"

  # Status-Sensor
  mqtt_publish_config \
    "${MQTT_DISCOVERY_PREFIX}/sensor/${NODE_NAME}_backup_status/config" \
    "$(cat <<EOF
{
  "name": "Backup Status ${NODE_NAME}",
  "state_topic": "${local_state_topic_status}",
  "value_template": "{{ value_json.phase }}",
  "unique_id": "${NODE_NAME}_backup_status",
  "object_id": "${NODE_NAME}_backup_status"
}
EOF
)"

  # Progress-Sensor
  mqtt_publish_config \
    "${MQTT_DISCOVERY_PREFIX}/sensor/${NODE_NAME}_backup_progress/config" \
    "$(cat <<EOF
{
  "name": "Backup Progress ${NODE_NAME}",
  "state_topic": "${local_state_topic_progress}",
  "unit_of_measurement": "%",
  "value_template": "{{ value_json.percent }}",
  "unique_id": "${NODE_NAME}_backup_progress",
  "object_id": "${NODE_NAME}_backup_progress"
}
EOF
)"
fi


if [[ -n "$LAST_RUN_INFO" ]]; then
  mqtt_publish_retained "status" "$(printf '{"phase":"starting","mode":"%s","last_run":%s}' "$MODE_TEXT" "$LAST_RUN_INFO")"
else
  mqtt_publish_retained "status" "$(printf '{"phase":"starting","mode":"%s"}' "$MODE_TEXT")"
fi

# ---- Letzter Lauf aus last_run.json (falls vorhanden) ----
last_human=""
last_dur=""
last_mode=""
last_sec=""

if [[ -n "$LAST_RUN_INFO" ]]; then
  last_human="$(echo "$LAST_RUN_INFO" | sed -n 's/.*"finished_at":"\([^"]*\)".*/\1/p')"
  last_dur="$(echo "$LAST_RUN_INFO" | sed -n 's/.*"duration":"\([^"]*\)".*/\1/p')"
  last_mode="$(echo "$LAST_RUN_INFO" | sed -n 's/.*"mode":"\([^"]*\)".*/\1/p')"
  last_sec="$(echo "$LAST_RUN_INFO" | sed -n 's/.*"seconds":\([0-9]\+\).*/\1/p')"
fi

# ---- Start-Summary bauen (mit echten Newlines) ----
SUMMARY_START=$(
  printf "%s" \
"Modus: ${MODE_TEXT}
Zero-Fill: ${ZERO_FILL}
Retention: ${RETENTION_COUNT}
Prefix: ${IMAGE_PREFIX}
Ziel-Datei: ${CIFS_SHARE}/${IMAGE_NAME}
Gotify-Nachrichten: ${GOTIFY_ENABLED}
MQTT-Nachrichten: ${MQTT_ENABLED}"
)

if [[ -n "${DEV:-}" ]]; then
  SUMMARY_START="${SUMMARY_START}"$'\n'"Device: ${BOOT_DEVICE}"
fi

# Letzter Lauf anhängen
if [[ -n "$last_human" || -n "$last_dur" ]]; then
  SUMMARY_START="${SUMMARY_START}"$'\n\n'"Letzter Lauf: ${last_human:-?} (${last_dur:-?})"
  [[ -n "$last_mode" ]] && SUMMARY_START="${SUMMARY_START}"$'\n'"Letzter Modus: ${last_mode}"
else
  SUMMARY_START="${SUMMARY_START}"$'\n\n'"Letzter Lauf: (keine Daten)"
fi

notify_gotify "Backup startet (${IMAGE_PREFIX})" "$SUMMARY_START" 4


# =========================
# Abhängigkeits-Checks
# =========================

# dd
if ! command -v dd &> /dev/null; then
  log_msg "❌ 'dd' wurde nicht gefunden."
  if ! $NON_INTERACTIVE && ask_yes_no "Versuchen, 'coreutils' (dd) zu installieren?" "J"; then
    if run_as_root apt-get update && run_as_root apt-get install -y coreutils; then
      log_msg "✅ coreutils installiert."
    else
      log_msg "❌ Installation von coreutils fehlgeschlagen. Breche ab."
      exit 1
    fi
  else
    log_msg "❌ Ohne 'dd' kein Backup möglich. Breche ab."
    exit 1
  fi
fi

# cifs-utils
ensure_cifs_utils

# Kompressor
ZIP_CMD="$(choose_compressor)"

log_msg "DEBUG: ZIP_CMD='${ZIP_CMD}'"

if ! command -v "$ZIP_CMD" &>/dev/null; then
  log_msg "❌ Kompressor '$ZIP_CMD' nicht gefunden – breche ab."
  exit 1
fi

# =========================
# Boot-Device Erkennung
# =========================

if [[ -n "${BOOT_DEVICE:-}" ]]; then
  DEV="$BOOT_DEVICE"
  log_msg "💾 Nutze manuell gesetztes Boot-Device: $DEV"
else
  BOOT_DEV="$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')"

  if [[ "$BOOT_DEV" == "/dev/mmcblk0p"* || "$BOOT_DEV" == "/dev/mmcblk0" ]]; then
    DEV="/dev/mmcblk0"
    log_msg "📀 Bootmedium: SD-Karte ($DEV)"
  elif [[ "$BOOT_DEV" == "/dev/sd"* ]]; then
    DEV="/dev/$(basename "$BOOT_DEV" | sed 's/[0-9]*$//')"
    log_msg "💾 Bootmedium: USB-SSD ($DEV)"
  elif [[ "$BOOT_DEV" == "overlay" || "$BOOT_DEV" == "/dev/root" ]]; then
    log_msg "❌ Root-Filesystem ist '${BOOT_DEV}' (vermutlich Container)."
    log_msg "   Bitte BOOT_DEVICE als ENV setzen, z.B.:"
    log_msg "   BOOT_DEVICE=/dev/sda  oder  BOOT_DEVICE=/dev/mmcblk0"
    exit 1
  else
    log_msg "❌ Unbekanntes Bootmedium: $BOOT_DEV"
    exit 1
  fi
fi

# =========================
# 0) Verzeichnis
# =========================

# 0) Zielverzeichnis im Container anlegen
mkdir -p "$BACKUP_DIR"

# 1) CIFS-Mount im Container
if ! mountpoint -q "$BACKUP_DIR"; then
  log_msg "[0/5] Mounten der Synology-Freigabe..."

  if [[ -z "$CIFS_PASS" ]]; then
    if $NON_INTERACTIVE; then
      log_msg "❌ CIFS_PASS ist im non-interactive Modus nicht gesetzt. Bitte per ENV oder --cifs-pass setzen." >&2
      exit 1
    else
      read -rs -p "Passwort für CIFS-Share Benutzer '${CIFS_USER}': " CIFS_PASS
      log_msg
    fi
  fi

  MOUNT_OPTS="username=${CIFS_USER},password=${CIFS_PASS},domain=${CIFS_DOMAIN},uid=${CIFS_UID},gid=${CIFS_GID},iocharset=utf8,vers=3.0,_netdev"

  if ! run_as_root mount -t cifs "$CIFS_SHARE" "$BACKUP_DIR" -o "$MOUNT_OPTS"; then
    log_msg "❌ CIFS-Share konnte NICHT gemountet werden! ($CIFS_SHARE)"
    exit 1
  fi
else
  log_msg "[0/5] Share bereits gemountet."
fi

# 1b) Sicherstellen, dass es WIRKLICH ein CIFS-Mount ist
log_msg "DEBUG: Mount-Check:"
mount | grep " on $BACKUP_DIR " || log_msg "WARN: Kein expliziter Mount-Eintrag für $BACKUP_DIR"

if mount | grep " on $BACKUP_DIR " | grep -q " type cifs"; then
  log_msg "✅ $BACKUP_DIR ist als CIFS gemountet."
else
  log_msg "❌ $BACKUP_DIR ist kein CIFS-Mount – breche ab, um nicht lokal alles vollzuschreiben."
  exit 1
fi

df -h "$BACKUP_DIR" || true

# 2) Docker Stop
log_msg "[1/5] Stoppe laufende Docker-Container..."

if ! command -v docker &>/dev/null; then
  log_msg "→ Docker nicht installiert, überspringe Container-Stop."
else
  # Eigenen Container / Name bestimmen
  SELF_ID=""
  if [[ -n "${HOSTNAME:-}" ]]; then
    SELF_ID="$HOSTNAME"  # Standard: Container-ID == HOSTNAME
  fi

  # Laufende Container holen (Fehler killt das Script NICHT)
  DOCKER_PS_OUTPUT="$(docker ps --format '{{.ID}} {{.Names}}' 2>&1)"
  PS_EXIT=$?

  if (( PS_EXIT != 0 )); then
    log_msg "⚠️ 'docker ps' fehlgeschlagen (Exit $PS_EXIT): $DOCKER_PS_OUTPUT"
    log_msg "→ Überspringe Container-Stop, fahre mit Backup fort."
    SAFE_TO_ROTATE=false
  else
    # In Array parsen
    mapfile -t ALL <<<"$DOCKER_PS_OUTPUT"
    local_running=${#ALL[@]}
    log_msg "DEBUG: docker ps liefert ${local_running} laufende Container."

    if (( local_running == 0 )); then
      log_msg "→ Keine laufenden Container."
    else
      CLEAN_IDS=()

      for line in "${ALL[@]}"; do
        cid="${line%% *}"
        cname="${line#* }"

        # führenden / bei Namen entfernen
        cname="${cname#/}"

        # eigenen Backup-Container ignorieren
        if [[ -n "$SELF_ID" && ( "$cid" == "$SELF_ID" || "$cname" == "$SELF_ID" ) ]]; then
          log_msg "DEBUG: Ignoriere eigenen Container $cname ($cid) beim Stoppen."
          continue
        fi

        # portainer_agent ebenfalls laufen lassen
        if [[ "$cname" == "portainer_agent" ]]; then
          log_msg "DEBUG: Ignoriere Portainer Agent ($cid) beim Stoppen."
          continue
        fi

        CLEAN_IDS+=("$cid")
      done

            if ((${#CLEAN_IDS[@]} == 0)); then
        log_msg "→ Nur Backup-Container/portainer_agent laufen, nichts weiter zu stoppen."
      else
        log_msg "DEBUG: Stoppe folgende Container-IDs: ${CLEAN_IDS[*]}"

        # Optional: komplett überspringen (z.B. zum Debuggen)
        if [[ "${SKIP_DOCKER_STOP}" == "true" ]]; then
          log_msg "DEBUG: SKIP_DOCKER_STOP=true → Container werden NICHT gestoppt."
        else
          # Wenn 'timeout' verfügbar ist, sichere den Aufruf ab
          if command -v timeout &>/dev/null; then
            # z.B. 120 Sekunden für alle zusammen
            if ! timeout 120 docker stop "${CLEAN_IDS[@]}"; then
              STOP_EXIT=$?
              log_msg "⚠️ docker stop (mit timeout) hat Exit-Code $STOP_EXIT geliefert – fahre trotzdem mit Backup fort."
              SAFE_TO_ROTATE=false
            else
              log_msg "DEBUG: docker stop fertig."
            fi
          else
            # Fallback ohne timeout
            if ! docker stop "${CLEAN_IDS[@]}"; then
              STOP_EXIT=$?
              log_msg "⚠️ docker stop hat Exit-Code $STOP_EXIT geliefert – fahre trotzdem mit Backup fort."
              SAFE_TO_ROTATE=false
            else
              log_msg "DEBUG: docker stop fertig."
            fi
          fi
        fi
      fi

    fi
  fi
fi


# 3) Backup
TOTAL_BYTES=0

# 3a) Versuch über blockdev
if command -v blockdev &>/dev/null; then
  TOTAL_BYTES="$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)"
fi

# 3b) Fallback über lsblk
if [[ "${TOTAL_BYTES:-0}" -eq 0 ]] && command -v lsblk &>/dev/null; then
  TOTAL_BYTES="$(lsblk -nbdo SIZE "$DEV" 2>/dev/null | head -n1 || echo 0)"
fi

# 3c) Fallback über /sys/block (funktioniert oft auch im Container)
if [[ "${TOTAL_BYTES:-0}" -eq 0 ]]; then
  dev_base="$(basename "$DEV")"
  # mmcblk0p1 -> mmcblk0 ; sda1 -> sda
  dev_base="${dev_base%%[0-9]*}"

  if [[ -r "/sys/block/$dev_base/size" ]]; then
    sectors="$(cat "/sys/block/$dev_base/size" 2>/dev/null || echo 0)"
    if [[ "$sectors" -gt 0 ]]; then
      TOTAL_BYTES=$((sectors * 512))
    fi
  fi
fi

log_msg "DEBUG: TOTAL_BYTES für $DEV = $TOTAL_BYTES"

if $DRY_RUN; then
  log_msg "[2/5] 🧪 Dry-Run: simuliere dd-Progress..."
  log_msg "    Geplante Backupdatei wäre: $BACKUP_DIR/$IMAGE_NAME"

  # Für HA/MQTT: sicherstellen, dass total nicht 0 ist
  [[ "${TOTAL_BYTES:-0}" -eq 0 ]] && TOTAL_BYTES=100

  # Status + Progress wie beim echten Lauf
  mqtt_publish_retained "status" \
    "$(printf '{"phase":"dd_start","mode":"%s","dry_run":true}' "$MODE_TEXT")"

  mqtt_publish_retained "progress" \
    "$(printf '{"phase":"dd_running","bytes":0,"total":%s,"percent":0}' "$TOTAL_BYTES")"

  for p in 0 25 50 75 100; do
  mqtt_publish_retained "progress" \
    "$(printf '{"phase":"dd_running","bytes":%s,"total":%s,"percent":%s}' \
      $((TOTAL_BYTES * p / 100)) "$TOTAL_BYTES" "$p")"
  sleep 2
  done

  mqtt_publish_retained "progress" \
    "$(printf '{"phase":"dd_done","bytes":%s,"total":%s,"percent":100}' "$TOTAL_BYTES" "$TOTAL_BYTES")"

  mqtt_publish_retained "status" \
    "$(printf '{"phase":"dd_done","mode":"%s","dry_run":true}' "$MODE_TEXT")"

  # Optional: Mini-Schreibtest (dein bisheriger Test)
  touch "$BACKUP_DIR/dry_run_test.txt" && rm "$BACKUP_DIR/dry_run_test.txt"

  BACKUP_SUCCESS=true
else
  if [[ "$ZERO_FILL" == "true" ]]; then
    zero_free_space
  else
    log_msg "🧹 Zero-Fill deaktiviert (ZERO_FILL=false)."
  fi

  log_msg "[2/5] Erstelle Image von $DEV..."
echo "[2/5] Erstelle Image von $DEV..."

mqtt_publish_retained "status" "$(printf '{"phase":"dd_start","mode":"%s"}' "$MODE_TEXT")"
mqtt_publish_retained "progress" "$(printf '{"phase":"dd_start","bytes":0,"total":%s,"percent":0}' "$TOTAL_BYTES")"

set +e
dd if="$DEV" bs=4M status=progress 2> >(
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -o0 -e0 tr '\r' '\n'
  else
    tr '\r' '\n'
  fi | dd_progress_reader
) | $ZIP_CMD > "$BACKUP_DIR/$IMAGE_NAME"
DD_EXIT=$?
set -e

if (( DD_EXIT != 0 )); then
  echo "❌ dd/pigz Exit-Code: $DD_EXIT" >&2
  mqtt_publish_retained "status" "$(printf '{"phase":"error","mode":"%s","dd_exit":%d}' "$MODE_TEXT" "$DD_EXIT")"
  exit 1
fi

sync

mqtt_publish_retained "progress" "$(printf '{"phase":"dd_done","bytes":%s,"total":%s,"percent":100}' "$TOTAL_BYTES" "$TOTAL_BYTES")"
mqtt_publish_retained "status" "$(printf '{"phase":"dd_done","mode":"%s"}' "$MODE_TEXT")"
BACKUP_SUCCESS=true
fi





# 4) Docker Start
log_msg "[3/5] Starte Docker-Container..."
mqtt_publish_retained "status" "$(printf '{"phase":"booting","mode":"%s"}' "$MODE_TEXT")"


if ! command -v docker &>/dev/null; then
  log_msg "→ Docker nicht installiert, überspringe Container-Start."
else
  USE_INTERNAL_START=false

  if [[ -d "$MARKER_DIR" && -f "$MARKER_DIR/dependencies.txt" && -f "$MARKER_DIR/first_boot_container.txt" && -x "$DOCKER_BOOT_SCRIPT" ]]; then
    log_msg "→ Marker & Orchestrierungs-Skript gefunden (dependencies.txt, first_boot_container.txt, $DOCKER_BOOT_SCRIPT)."
    log_msg "   Delegiere Start an docker-boot-start.sh ..."

    if "$DOCKER_BOOT_SCRIPT"; then
      log_msg "✅ Orchestrierungs-Skript erfolgreich ausgeführt."
    else
      log_msg "⚠️ Orchestrierungs-Skript meldet Fehler – nutze Fallback-Startlogik."
      USE_INTERNAL_START=true
    fi
  else
    log_msg "→ Marker-Setup unvollständig oder nicht vorhanden – nutze interne Startlogik."
    USE_INTERNAL_START=true
  fi

  if [[ "$USE_INTERNAL_START" == true ]]; then
    mapfile -t ALL <<EOF
$(docker ps -a --format '{{.ID}} {{.Names}}')
EOF

    if ((${#ALL[@]} == 0)); then
      log_msg "→ Keine Container vorhanden."
    else
      declare -a BUCKET_OTHERS=()
      declare -a BUCKET_CROWDSEC=()
      declare -a BUCKET_OPENAPPSEC=()
      declare -a BUCKET_NPMPLUS=()

      for line in "${ALL[@]}"; do
        cid="${line%% *}"
        cname="${line#* }"
        cname_lc="${cname,,}"

        case "$cname_lc" in
          *npmplus*|*nginx-proxy-manager*|*npm-plus*) BUCKET_NPMPLUS+=("$cid") ;;
          *crowdsec*)                                BUCKET_CROWDSEC+=("$cid") ;;
          *openappsec*|*open-appsec*)                BUCKET_OPENAPPSEC+=("$cid") ;;
          *)                                         BUCKET_OTHERS+=("$cid") ;;
        esac
      done

      start_group() {
        local -a ids=("$@")
        local -a to_start=()
        for id in "${ids[@]}"; do
          if [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" != "true" ]]; then
            to_start+=("$id")
          fi
        done
        if ((${#to_start[@]})); then
          docker start "${to_start[@]}"
        fi
      }

      [[ ${#BUCKET_OTHERS[@]}     -gt 0 ]] && { log_msg "→ Others...";     start_group "${BUCKET_OTHERS[@]}"; }
      [[ ${#BUCKET_CROWDSEC[@]}   -gt 0 ]] && { log_msg "→ CrowdSec...";   start_group "${BUCKET_CROWDSEC[@]}"; }
      [[ ${#BUCKET_OPENAPPSEC[@]} -gt 0 ]] && { log_msg "→ OpenAppSec..."; start_group "${BUCKET_OPENAPPSEC[@]}"; }

      if ((${#BUCKET_NPMPLUS[@]})); then
        log_msg "⏳ Warte ${START_DELAY}s vor Start von NPM Plus..."
        sleep "${START_DELAY}"
        log_msg "→ NPM Plus..."
        start_group "${BUCKET_NPMPLUS[@]}"
      fi
    fi
  fi
fi

mqtt_publish_retained "status" "$(printf '{"phase":"boot_done","mode":"%s"}' "$MODE_TEXT")"

# 4b) Healthcheck nach Stack-Start
if ! $DRY_RUN && $HEALTH_CHECK; then
  log_msg "🔍 Healthcheck des Backups läuft..."
  if $ZIP_CMD -t "$BACKUP_DIR/$IMAGE_NAME"; then
    log_msg "✅ Healthcheck OK: Archiv scheint in Ordnung."
    HEALTHCHECK_OK=true
  else
    log_msg "❌ Healthcheck fehlgeschlagen! Archiv könnte korrupt sein."
    HEALTHCHECK_OK=false
    SAFE_TO_ROTATE=false            # ganz wichtig: nichts löschen!
    notify_gotify "Backup Healthcheck FEHLER" \
      "Healthcheck für $BACKUP_DIR/$IMAGE_NAME auf ${IMAGE_PREFIX} ist fehlgeschlagen." \
      7
  fi
else
  # Kein Healthcheck angefordert → Healthcheck gilt als "nicht relevant"
  HEALTHCHECK_OK=true
fi


# 4c) Rotation – NUR wenn Backup sauber & System-Status ok
if ! $DRY_RUN; then
  if [[ "$BACKUP_SUCCESS" == true && "$SAFE_TO_ROTATE" == true && "$HEALTHCHECK_OK" == true ]]; then
    log_msg "🧹 Rotation aktiviert (BACKUP_SUCCESS=true, SAFE_TO_ROTATE=true, HEALTHCHECK_OK=true)."
    rotate_backups
  else
    log_msg "🧹 Rotation übersprungen (BACKUP_SUCCESS=${BACKUP_SUCCESS}, SAFE_TO_ROTATE=${SAFE_TO_ROTATE}, HEALTHCHECK_OK=${HEALTHCHECK_OK})."
    log_msg "   → Letzte bekannte heile Backups werden NICHT angerührt."
  fi
fi

# 5) Abschlussmeldung
if $DRY_RUN; then
  log_msg "[4/5] Backup (Dry-Run) abgeschlossen."
  log_msg "    Geplanter Pfad: $BACKUP_DIR/$IMAGE_NAME ✅"
else
  log_msg "[4/5] Backup fertig: $BACKUP_DIR/$IMAGE_NAME ✅"
fi

# 6) Unmount
log_msg "[5/5] Unmount..."
run_as_root umount "$BACKUP_DIR" || log_msg "→ Unmount fehlgeschlagen/bereits unmounted."

# =========================
# Zeitmessung & Gotify & MQTT-Finalstatus
# =========================
END_TS="$(date +%s)"
DURATION_SEC=$(( END_TS - START_TS ))
END_HUMAN="$(date '+%d.%m.%Y %H:%M')"
DURATION_STR="$(format_duration "$DURATION_SEC")"

MODE_TEXT="Normal"
$DRY_RUN && MODE_TEXT="Dry-Run"
$HEALTH_CHECK && MODE_TEXT="${MODE_TEXT} + Healthcheck"

SUMMARY="Modus: ${MODE_TEXT}
Zero-Fill: ${ZERO_FILL}
Dauer: ${DURATION_STR}
Fertiggestellt: ${END_HUMAN}
Datei: ${CIFS_SHARE}/${IMAGE_NAME}"

if $DRY_RUN; then
  # last_run ggf. aus Datei laden (falls nicht schon geladen)
  if [[ -z "${LAST_RUN_INFO:-}" && -n "${LAST_RUN_FILE:-}" && -r "$LAST_RUN_FILE" ]]; then
    LAST_RUN_INFO="$(cat "$LAST_RUN_FILE" 2>/dev/null || true)"
  fi

  log_msg "⏱ Laufzeit (Dry-Run): $DURATION_STR"
  notify_gotify "Backup Dry-Run OK" \
    "Dry-Run erfolgreich auf ${IMAGE_PREFIX}
${SUMMARY}" \
    4

  if [[ -n "${LAST_RUN_INFO:-}" ]]; then
    mqtt_publish_retained "status" \
      "$(printf '{"phase":"success","mode":"%s","dry_run":true,"duration":"%s","finished_at":"%s","last_run":%s}' \
        "$MODE_TEXT" "$DURATION_STR" "$END_HUMAN" "$LAST_RUN_INFO")"
  else
    mqtt_publish_retained "status" \
      "$(printf '{"phase":"success","mode":"%s","dry_run":true,"duration":"%s","finished_at":"%s"}' \
        "$MODE_TEXT" "$DURATION_STR" "$END_HUMAN")"
  fi

else
  # last_run.json aktualisieren
  if [[ -n "${LAST_RUN_FILE:-}" ]]; then
    cat > "$LAST_RUN_FILE" <<EOF
{"finished_at":"$END_HUMAN","duration":"$DURATION_STR","seconds":$DURATION_SEC,"mode":"$MODE_TEXT"}
EOF
    LAST_RUN_INFO="$(cat "$LAST_RUN_FILE" 2>/dev/null || true)"
  fi

  # finaler retained Status publishen (inkl. last_run, falls vorhanden)
  if [[ -n "${LAST_RUN_INFO:-}" ]]; then
    mqtt_publish_retained "status" \
      "$(printf '{"phase":"success","mode":"%s","dry_run":false,"duration":"%s","finished_at":"%s","last_run":%s}' \
        "$MODE_TEXT" "$DURATION_STR" "$END_HUMAN" "$LAST_RUN_INFO")"
  else
    mqtt_publish_retained "status" \
      "$(printf '{"phase":"success","mode":"%s","dry_run":false,"duration":"%s","finished_at":"%s"}' \
        "$MODE_TEXT" "$DURATION_STR" "$END_HUMAN")"
  fi

  log_msg "⏱ Laufzeit: $DURATION_STR"
  notify_gotify "Backup erfolgreich" \
    "Backup erfolgreich auf ${IMAGE_PREFIX}
${SUMMARY}" \
    5
fi
