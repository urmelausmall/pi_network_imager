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

# Per ENV überschreibbar
START_DELAY="${START_DELAY:-15}"                 # Sekunden vor Start von NPM Plus
IMAGE_PREFIX="${IMAGE_PREFIX:-raspi-4gb-}"      # Standard-Präfix für Backupdatei
RETENTION_COUNT="${RETENTION_COUNT:-2}"         # inkl. aktuellem Backup

# Pfade / Shares (per ENV anpassbar)
BACKUP_DIR="${BACKUP_DIR:-/mnt/syno-backup}"
CIFS_SHARE="${CIFS_SHARE:-//192.168.178.25/System_Backup}"
MARKER_DIR="${MARKER_DIR:-/markers}"
DOCKER_BOOT_SCRIPT="${DOCKER_BOOT_SCRIPT:-/app/docker-boot-start.sh}"


# CIFS Auth – portabel konfigurierbar
CIFS_USER="${CIFS_USER:-User}"       # Standard-User, per ENV/CLI änderbar
CIFS_DOMAIN="${CIFS_DOMAIN:-WORKGROUP}"
CIFS_PASS="${CIFS_PASS:-}"                   # lieber über ENV setzen statt im Script
CIFS_UID="${CIFS_UID:-1000}"
CIFS_GID="${CIFS_GID:-1000}"

# Gotify Defaults (per ENV überschreibbar)
GOTIFY_URL="${GOTIFY_URL:-http://192.168.178.25:6742}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-ALP6Ru9PccuRao_}"
GOTIFY_ENABLED="${GOTIFY_ENABLED:-true}"

# =========================
# Funktionen
# =========================

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
  if command -v run_as_root &>/dev/null; then
    run_as_root "$@"
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

# <<< NEU: curl-Checker mit Install-Option
ensure_curl() {
  if command -v curl &>/dev/null; then
    return 0
  fi

  echo "❌ 'curl' wurde nicht gefunden, wird aber für Gotify-Notifications benötigt." >&2

  if $NON_INTERACTIVE; then
    echo "Versuche automatische Installation von 'curl'..." >&2
    if run_as_root apt-get update && run_as_root apt-get install -y curl; then
      echo "✅ curl installiert." >&2
      return 0
    else
      echo "❌ Installation von curl fehlgeschlagen. Es werden keine Gotify-Notifications gesendet." >&2
      return 1
    fi
  else
    if ask_yes_no "curl installieren? (für Gotify-Notifications benötigt)" "J"; then
      if run_as_root apt-get update && run_as_root apt-get install -y curl; then
        echo "✅ curl installiert." >&2
        return 0
      else
        echo "❌ Installation von curl fehlgeschlagen. Es werden keine Gotify-Notifications gesendet." >&2
        return 1
      fi
    else
      echo "ℹ️ Ohne curl werden keine Gotify-Notifications gesendet." >&2
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

choose_compressor() {
  local zip_cmd=""

  if command -v pigz &> /dev/null; then
    zip_cmd="pigz"
    echo "🚀 pigz gefunden! Nutze Multi-Core-Kompression." >&2
    echo "$zip_cmd"
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
    echo "🧹 Retention: ${total} Backups gefunden, nichts zu löschen (Limit: ${RETENTION_COUNT})."
    return 0
  fi

  IFS=$'\n' files=($(printf '%s\n' "${files[@]}" | sort))
  unset IFS

  local to_delete_count=$(( total - RETENTION_COUNT ))
  local delete_list=( "${files[@]:0:to_delete_count}" )

  echo "🧹 Retention aktiv: Behalte die letzten ${RETENTION_COUNT} Backups, lösche ${#delete_list[@]} ältere:"
  for f in "${delete_list[@]}"; do
    echo "   → Lösche $f"
    rm -f -- "$f"
  done
}

ensure_cifs_utils() {
  if command -v mount.cifs &>/dev/null; then
    return 0
  fi

  echo "❌ CIFS-Tools ('cifs-utils') wurden nicht gefunden." >&2

  if $NON_INTERACTIVE; then
    echo "Versuche automatische Installation von 'cifs-utils'..." >&2
    if run_as_root apt-get update && run_as_root apt-get install -y cifs-utils; then
      echo "✅ cifs-utils installiert." >&2
      return 0
    else
      echo "❌ Installation von cifs-utils fehlgeschlagen. Breche ab." >&2
      exit 1
    fi
  else
    if ask_yes_no "cifs-utils installieren? (für CIFS-Mount benötigt)" "J"; then
      if run_as_root apt-get update && run_as_root apt-get install -y cifs-utils; then
        echo "✅ cifs-utils installiert." >&2
        return 0
      else
        echo "❌ Installation von cifs-utils fehlgeschlagen. Breche ab." >&2
        exit 1
      fi
    else
      echo "❌ Ohne cifs-utils kein CIFS-Mount möglich. Breche ab." >&2
      exit 1
    fi
  fi
}

ensure_supported_system() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      raspbian|debian)
        ;;
      *)
        echo "⚠️ Achtung: System ist nicht als Raspberry Pi OS/Debian erkannt (ID='${ID:-unbekannt}')." >&2
        echo "   Script ist primär für Raspberry Pi OS / Debian gedacht." >&2
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

  notify_gotify "Backup FEHLGESCHLAGEN" \
    "Backup-Script auf $(hostname) ist mit Exit-Code ${exit_code} abgebrochen.
Fertiggestellt (Fehler): ${end_human} (${dur_str})." \
    8
}
trap 'on_error' ERR

# -------------------------
# Systemcheck ausführen
# -------------------------
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
    --delay|-d)
      shift
      [[ $# -gt 0 ]] || { echo "Fehlender Wert für --delay" >&2; exit 2; }
      START_DELAY="$1"; shift
      ;;
    --prefix|-p)
      shift
      [[ $# -gt 0 ]] || { echo "Fehlender Wert für --prefix" >&2; exit 2; }
      IMAGE_PREFIX="$1"
      shift
      ;;
    --keep|-k)
      shift
      [[ $# -gt 0 ]] || { echo "Fehlender Wert für --keep" >&2; exit 2; }
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
      [[ $# -gt 0 ]] || { echo "Fehlender Wert für --cifs-user" >&2; exit 2; }
      CIFS_USER="$1"
      shift
      ;;
    --cifs-pass)
      shift
      [[ $# -gt 0 ]] || { echo "Fehlender Wert für --cifs-pass" >&2; exit 2; }
      CIFS_PASS="$1"
      shift
      ;;
    --cifs-domain)
      shift
      [[ $# -gt 0 ]] || { echo "Fehlender Wert für --cifs-domain" >&2; exit 2; }
      CIFS_DOMAIN="$1"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unbekannte Option: $1" >&2
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
# Dynamische Namen
# =========================
DATE_STR="$(date +%F_%H%M)"
IMAGE_NAME="${IMAGE_PREFIX}${DATE_STR}.img.gz"

# =========================
# Abhängigkeits-Checks
# =========================

# dd
if ! command -v dd &> /dev/null; then
  echo "❌ 'dd' wurde nicht gefunden."
  if ! $NON_INTERACTIVE && ask_yes_no "Versuchen, 'coreutils' (dd) zu installieren?" "J"; then
    if run_as_root apt-get update && run_as_root apt-get install -y coreutils; then
      echo "✅ coreutils installiert."
    else
      echo "❌ Installation von coreutils fehlgeschlagen. Breche ab."
      exit 1
    fi
  else
    echo "❌ Ohne 'dd' kein Backup möglich. Breche ab."
    exit 1
  fi
fi

# cifs-utils
ensure_cifs_utils

# Kompressor
ZIP_CMD="$(choose_compressor)"

# =========================
# Boot-Device Erkennung
# =========================

if [[ -n "${BOOT_DEVICE:-}" ]]; then
  # explizit per ENV gesetzt (z.B. im Container)
  DEV="$BOOT_DEVICE"
  echo "💾 Nutze manuell gesetztes Boot-Device: $DEV"
else
  # Auto-Detection (typisch auf nacktem Pi)
  BOOT_DEV="$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')"

  if [[ "$BOOT_DEV" == "/dev/mmcblk0p"* || "$BOOT_DEV" == "/dev/mmcblk0" ]]; then
    DEV="/dev/mmcblk0"
    echo "📀 Bootmedium: SD-Karte ($DEV)"
  elif [[ "$BOOT_DEV" == "/dev/sd"* ]]; then
    DEV="/dev/$(basename "$BOOT_DEV" | sed 's/[0-9]*$//')"
    echo "💾 Bootmedium: USB-SSD ($DEV)"
  elif [[ "$BOOT_DEV" == "overlay" || "$BOOT_DEV" == "/dev/root" ]]; then
    echo "❌ Root-Filesystem ist '${BOOT_DEV}' (vermutlich Container)."
    echo "   Bitte BOOT_DEVICE als ENV setzen, z.B.:"
    echo "   BOOT_DEVICE=/dev/sda  oder  BOOT_DEVICE=/dev/mmcblk0"
    exit 1
  else
    echo "❌ Unbekanntes Bootmedium: $BOOT_DEV"
    exit 1
  fi
fi


# =========================
# 0) Verzeichnis
# =========================
mkdir -p "$BACKUP_DIR"

# 1) Mount
if ! mountpoint -q "$BACKUP_DIR"; then
  echo "[0/5] Mounten der Synology-Freigabe..."

  if [[ -z "$CIFS_PASS" ]]; then
    if $NON_INTERACTIVE; then
      echo "❌ CIFS_PASS ist im non-interactive Modus nicht gesetzt. Bitte per ENV oder --cifs-pass setzen." >&2
      exit 1
    else
      read -rs -p "Passwort für CIFS-Share Benutzer '${CIFS_USER}': " CIFS_PASS
      echo
    fi
  fi

  MOUNT_OPTS="username=${CIFS_USER},password=${CIFS_PASS},domain=${CIFS_DOMAIN},uid=${CIFS_UID},gid=${CIFS_GID},iocharset=utf8,vers=3.0,_netdev"

  run_as_root mount -t cifs "$CIFS_SHARE" "$BACKUP_DIR" -o "$MOUNT_OPTS"
else
  echo "[0/5] Share bereits gemountet."
fi

# 2) Docker Stop
echo "[1/5] Stoppe laufende Docker-Container..."
if command -v docker &>/dev/null; then
  # eigene Container-ID (falls im Container mit /var/run/docker.sock)
  SELF_ID=""
  if [[ -n "${HOSTNAME:-}" ]]; then
    # versucht, den eigenen Container über ID-Prefix zu finden
    SELF_ID="$(docker ps -q -f id="$HOSTNAME" 2>/dev/null || true)"
  fi

  RUNNING_IDS=($(docker ps -q))
  if ((${#RUNNING_IDS[@]})); then
    CLEAN_IDS=()
    for id in "${RUNNING_IDS[@]}"; do
      # Eigenen Container nicht stoppen
      if [[ -n "$SELF_ID" && "$id" == "$SELF_ID" ]]; then
        continue
      fi
      CLEAN_IDS+=("$id")
    done

    if ((${#CLEAN_IDS[@]})); then
      docker stop "${CLEAN_IDS[@]}"
    else
      echo "→ Nur Backup-Container läuft, nichts zu stoppen."
    fi
  else
    echo "→ Keine laufenden Container."
  fi
else
  echo "→ Docker nicht installiert, überspringe Container-Stop."
fi


# 3) Backup
if $DRY_RUN; then
  echo "[2/5] 🧪 Dry-Run: Überspringe dd..."
  echo "    Geplante Backupdatei wäre: $BACKUP_DIR/$IMAGE_NAME"
  touch "$BACKUP_DIR/dry_run_test.txt" && rm "$BACKUP_DIR/dry_run_test.txt"
else
  echo "[2/5] Erstelle Image von $DEV..."
  run_as_root dd if="$DEV" bs=4M status=progress | $ZIP_CMD > "$BACKUP_DIR/$IMAGE_NAME"
  sync
fi

# 3b) Rotation
if ! $DRY_RUN; then
  rotate_backups
fi

# 4) Docker Start
echo "[3/5] Starte Docker-Container..."

if ! command -v docker &>/dev/null; then
  echo "→ Docker nicht installiert, überspringe Container-Start."
else
  USE_INTERNAL_START=false

  # Prüfe Marker-Ordner + Dateien:
  # - Ordner vorhanden
  # - first_boot vorhanden
  # - dependencies vorhanden
  # - eingebautes Orchestrierungs-Skript existiert & ausführbar
if [[ -d "$MARKER_DIR" && -f "$MARKER_DIR/dependencies.txt" && -f "$MARKER_DIR/first_boot_container.txt" && -x "$DOCKER_BOOT_SCRIPT" ]]; then
  echo "→ Marker & Orchestrierungs-Skript gefunden (dependencies.txt, first_boot_container.txt, $DOCKER_BOOT_SCRIPT)."
    echo "   Delegiere Start an docker-boot-start.sh ..."

    if "$DOCKER_BOOT_SCRIPT"; then
      echo "✅ Orchestrierungs-Skript erfolgreich ausgeführt."
    else
      echo "⚠️ Orchestrierungs-Skript meldet Fehler – nutze Fallback-Startlogik."
      USE_INTERNAL_START=true
    fi
  else
    echo "→ Marker-Setup unvollständig oder nicht vorhanden – nutze interne Startlogik."
    USE_INTERNAL_START=true
  fi

  if [[ "$USE_INTERNAL_START" == true ]]; then
    mapfile -t ALL <<EOF
$(docker ps -a --format '{{.ID}} {{.Names}}')
EOF

    if ((${#ALL[@]} == 0)); then
      echo "→ Keine Container vorhanden."
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

      [[ ${#BUCKET_OTHERS[@]}     -gt 0 ]] && { echo "→ Others...";     start_group "${BUCKET_OTHERS[@]}"; }
      [[ ${#BUCKET_CROWDSEC[@]}   -gt 0 ]] && { echo "→ CrowdSec...";   start_group "${BUCKET_CROWDSEC[@]}"; }
      [[ ${#BUCKET_OPENAPPSEC[@]} -gt 0 ]] && { echo "→ OpenAppSec..."; start_group "${BUCKET_OPENAPPSEC[@]}"; }

      if ((${#BUCKET_NPMPLUS[@]})); then
        echo "⏳ Warte ${START_DELAY}s vor Start von NPM Plus..."
        sleep "${START_DELAY}"
        echo "→ NPM Plus..."
        start_group "${BUCKET_NPMPLUS[@]}"
      fi
    fi
  fi
fi




# 4b) Healthcheck nach Stack-Start
if ! $DRY_RUN && $HEALTH_CHECK; then
  echo "🔍 Healthcheck des Backups läuft..."
  if $ZIP_CMD -t "$BACKUP_DIR/$IMAGE_NAME"; then
    echo "✅ Healthcheck OK: Archiv scheint in Ordnung."
  else
    echo "❌ Healthcheck fehlgeschlagen! Archiv könnte korrupt sein."
    notify_gotify "Backup Healthcheck FEHLER" \
      "Healthcheck für $BACKUP_DIR/$IMAGE_NAME auf $(hostname) ist fehlgeschlagen." \
      7
  fi
fi

# 5) Abschlussmeldung
if $DRY_RUN; then
  echo "[4/5] Backup (Dry-Run) abgeschlossen."
  echo "    Geplanter Pfad: $BACKUP_DIR/$IMAGE_NAME ✅"
else
  echo "[4/5] Backup fertig: $BACKUP_DIR/$IMAGE_NAME ✅"
fi

# 6) Unmount
echo "[5/5] Unmount..."
run_as_root umount "$BACKUP_DIR" || echo "→ Unmount fehlgeschlagen/bereits unmounted."

# =========================
# Zeitmessung & Gotify
# =========================
END_TS="$(date +%s)"
DURATION_SEC=$(( END_TS - START_TS ))
END_HUMAN="$(date '+%d.%m.%Y %H:%M')"
DURATION_STR="$(format_duration "$DURATION_SEC")"

if $DRY_RUN; then
  echo "⏱ Laufzeit (Dry-Run): $DURATION_STR"
  notify_gotify "Backup Dry-Run OK" \
    "Backup Dry-Run auf $(hostname) erfolgreich.
Geplante Datei: $BACKUP_DIR/$IMAGE_NAME
Fertiggestellt: ${END_HUMAN} (${DURATION_STR})." \
    4
else
  echo "⏱ Laufzeit: $DURATION_STR"
  notify_gotify "Backup erfolgreich" \
    "Backup auf $(hostname) erfolgreich:
$BACKUP_DIR/$IMAGE_NAME
Retention: ${RETENTION_COUNT}
Fertiggestellt: ${END_HUMAN} (${DURATION_STR})." \
    5
fi
