#!/usr/bin/env bash
set -euo pipefail

ORCH_PATH="/usr/local/sbin/pi-backup-orchestrator.sh"
SERVICE_PATH="/etc/systemd/system/pi-backup-orchestrator.service"

# Optional: alte Unit(s), die du früher hattest
OLD_UNITS=(
  "pi-backup-reboot-watcher.service"
)

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Bitte als root ausführen: sudo $0"
    exit 1
  fi
}

install_deps() {
  echo "[setup] Installiere Abhängigkeiten..."
  apt-get update
  apt-get install -y --no-install-recommends \
    curl pigz gzip cifs-utils mosquitto-clients util-linux
}

ensure_bootorder_allows_sd() {
  echo "[setup] Prüfe Raspberry Pi Bootloader (EEPROM) Boot-Order..."

  local current=""
  local cfg=""

  if command -v vcgencmd >/dev/null 2>&1; then
    cfg="$(vcgencmd bootloader_config 2>/dev/null || true)"
    current="$(echo "$cfg" | awk -F= 'BEGIN{IGNORECASE=1} $1 ~ /BOOT_ORDER/ {gsub(/[[:space:]]/,"",$2); print $2; exit}')"
  fi

  if [[ -z "$current" ]] && command -v rpi-eeprom-config >/dev/null 2>&1; then
    cfg="$(rpi-eeprom-config 2>/dev/null || true)"
    current="$(echo "$cfg" | awk -F= 'BEGIN{IGNORECASE=1} $1 ~ /BOOT_ORDER/ {gsub(/[[:space:]]/,"",$2); print $2; exit}')"
  fi

  if [[ -n "$current" ]]; then
    echo "[setup] Aktueller BOOT_ORDER: ${current}"
  else
    echo "[setup] WARN: BOOT_ORDER nicht gefunden – wird bei Bedarf angelegt."
  fi

  local desired="0x14"   # SD -> USB

  # Schon gut?
  if [[ -n "$current" ]]; then
    if [[ "${current,,}" == 0x14 ]] || [[ "${current,,}" == 0x1* ]]; then
      echo "[setup] BOOT_ORDER erlaubt SD->USB bereits – OK."
      return 0
    fi
  fi

  if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    echo "[setup] WARN: rpi-eeprom-config fehlt – kann BOOT_ORDER nicht setzen."
    return 0
  fi

  echo "[setup] Setze/erzeuge BOOT_ORDER=${desired} (SD -> USB)..."

  local tmp_in=""
  local tmp_out=""

  cleanup_tmp() {
    # robust gegen set -u
    [[ -n "${tmp_in:-}"  ]] && rm -f -- "${tmp_in}"  || true
    [[ -n "${tmp_out:-}" ]] && rm -f -- "${tmp_out}" || true
  }
  trap cleanup_tmp RETURN

  tmp_in="$(mktemp)"
  tmp_out="$(mktemp)"

  rpi-eeprom-config > "$tmp_in"

  if grep -qiE '^[#[:space:]]*BOOT_ORDER=' "$tmp_in"; then
    sed -E 's|^[#[:space:]]*BOOT_ORDER=.*|BOOT_ORDER='"${desired}"'|I' "$tmp_in" > "$tmp_out"
  else
    cat "$tmp_in" > "$tmp_out"
    echo "BOOT_ORDER=${desired}" >> "$tmp_out"
  fi

  if rpi-eeprom-config --apply "$tmp_out"; then
    echo "[setup] EEPROM Update eingeplant. Reboot erforderlich."
  else
    echo "[setup] WARN: EEPROM Apply fehlgeschlagen. Bitte manuell prüfen."
    return 0
  fi
}




setup_backup_shared_mount_mainos() {
  local LABEL_NAME="BACKUP_SHARED"
  local MOUNT_POINT="/backupos_shared"
  local FSTAB_LINE="LABEL=${LABEL_NAME}  ${MOUNT_POINT}  ext4  defaults,nofail,x-systemd.automount  0  2"

  echo "[setup] Shared-Mount im Main-OS vorbereiten (${LABEL_NAME} -> ${MOUNT_POINT})..."

  mkdir -p "$MOUNT_POINT"

  # 1) Prüfen ob Label im System sichtbar ist
  if ! blkid -L "$LABEL_NAME" >/dev/null 2>&1; then
    echo "[setup] WARN: LABEL=${LABEL_NAME} aktuell nicht sichtbar."
    echo "[setup]       - Ist das BACKUP_SHARED Volume angeschlossen?"
    echo "[setup]       - Falls es per USB-Platte kommt: ist die Platte gemountet/da?"
    echo "[setup]       Ich trage trotzdem fstab ein (nofail), dann klappt es später automatisch."
  fi

  # 2) fstab-Eintrag nur hinzufügen, wenn nicht vorhanden
  if grep -qE "^[^#]*LABEL=${LABEL_NAME}[[:space:]]+${MOUNT_POINT}" /etc/fstab; then
    echo "[setup] fstab-Eintrag existiert bereits."
  else
    echo "[setup] Ergänze /etc/fstab..."
    echo "$FSTAB_LINE" >> /etc/fstab
  fi

  # 3) systemd + mount testen (ohne Boot zu riskieren)
  systemctl daemon-reload || true

  if mountpoint -q "$MOUNT_POINT"; then
    echo "[setup] ${MOUNT_POINT} ist bereits gemountet."
  else
    echo "[setup] Teste Mount via mount -a (nofail => kein Hard-Fail)..."
    mount -a || true
  fi

  # 4) Ausgabe
  if mountpoint -q "$MOUNT_POINT"; then
    echo "[setup] OK: Shared-Mount aktiv: ${MOUNT_POINT}"
  else
    echo "[setup] Hinweis: Shared-Mount nicht aktiv (noch nicht verfügbar) – wird automatisch gemountet sobald Device da ist."
  fi
}

init_bootos_net_env_mainos() {
  local shared="/backupos_shared"
  local out="${shared}/bootos_net.env"

  echo "[setup] Lege initial bootos_net.env an (best effort)..."

  mkdir -p "$shared"
  mountpoint -q "$shared" || mount -a || true

  local iface gw cidr
  iface="$(ip route show default 0.0.0.0/0 2>/dev/null | awk '{print $5; exit}')"
  gw="$(ip route show default 0.0.0.0/0 2>/dev/null | awk '{print $3; exit}')"
  if [[ -n "$iface" ]]; then
    cidr="$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2; exit}')"
  fi

  if [[ -n "${iface:-}" && -n "${gw:-}" && -n "${cidr:-}" ]]; then
    cat > "$out" <<EOF
IFACE="${iface}"
CIDR="${cidr}"
GW="${gw}"
EOF
    sync
    echo "[setup] OK: ${out} geschrieben (${iface} / ${cidr} / gw ${gw})"
  else
    echo "[setup] WARN: Konnte Default-Netz nicht sauber erkennen – bootos_net.env nicht erstellt."
  fi
}


write_orchestrator() {
  echo "[setup] Schreibe Orchestrator nach ${ORCH_PATH}..."

  cat > "$ORCH_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Pi Backup Orchestrator (Main-OS) - v2 (patched)
# ============================================================

SHARED_DIR="${SHARED_DIR:-/backupos_shared}"

BACKUP_FLAG="${SHARED_DIR}/backup.flag"
BACKUP_REQ="${SHARED_DIR}/backup_request.env"
BACKUP_STATUS_ENV="${SHARED_DIR}/backup_status.env"
BACKUP_STATUS_JSON="${SHARED_DIR}/backup_status.json"

SD_FLAG="${SHARED_DIR}/sdimage.flag"
SD_REQ="${SHARED_DIR}/sdimage_request.env"
SD_STATUS_ENV="${SHARED_DIR}/sdimage_status.env"
SD_STATUS_JSON="${SHARED_DIR}/sdimage_status.json"

GUARD_FILE="${SHARED_DIR}/last_host_reboot.ts"
MIN_REBOOT_INTERVAL_SEC="${MIN_REBOOT_INTERVAL_SEC:-300}"

SD_BOOT_MNT="${SD_BOOT_MNT:-/mnt/sdboot}"
BOOT_OS_TAG="${BOOT_OS_TAG:-[Boot_OS]}"
CLEANUP_REQUEST_ON_COMPLETE="${CLEANUP_REQUEST_ON_COMPLETE:-false}"

log(){ echo "[$(date '+%F %T')] [orchestrator] $*" >&2; }

flag_state() {
  local f="$1"
  [[ -f "$f" ]] || { echo ""; return 0; }
  head -n1 "$f" 2>/dev/null | tr -d '\r' | awk '{print $1}'
}

write_flag() {
  local f="$1" v="$2"
  echo "$v" > "$f" 2>/dev/null || true
  sync
}

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

notify_gotify() {
  local title="$1"
  local message="$2"
  local priority="${3:-5}"

  [[ "${GOTIFY_ENABLED:-true}" == "true" ]] || return 0
  [[ -n "${GOTIFY_URL:-}" && -n "${GOTIFY_TOKEN:-}" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  curl -sS -X POST "${GOTIFY_URL%/}/message?token=${GOTIFY_TOKEN}" \
    -F "title=${title}" \
    -F "message=${message}" \
    -F "priority=${priority}" \
    >/dev/null || true
}

mqtt_publish_retained() {
  local topic="$1"
  local payload="$2"
  [[ "${MQTT_ENABLED:-false}" == "true" ]] || return 0
  command -v mosquitto_pub >/dev/null 2>&1 || return 0

  local host="${MQTT_HOST:-127.0.0.1}"
  local port="${MQTT_PORT:-1883}"
  local user="${MQTT_USER:-}"
  local pass="${MQTT_PASS:-}"
  local tls="${MQTT_TLS:-false}"

  local args=(-h "$host" -p "$port" -t "$topic" -m "$payload" -r)
  [[ -n "$user" ]] && args+=( -u "$user" )
  [[ -n "$pass" ]] && args+=( -P "$pass" )
  [[ "${tls,,}" == "true" ]] && args+=( --tls-version tlsv1.2 )

  mosquitto_pub "${args[@]}" >/dev/null 2>&1 || true
}

node_name() {
  if [[ -n "${BACKUP_NODE_NAME:-}" ]]; then
    echo "$BACKUP_NODE_NAME"
  else
    hostname
  fi
}

load_req_env() {
  local req="$1"
  set -a
  # shellcheck source=/dev/null
  source "$req"
  set +a
}

detect_main_net() {
  IFACE=""
  CIDR=""
  GW=""

  IFACE="$(ip route show default 0.0.0.0/0 2>/dev/null | awk '{print $5; exit}')"
  GW="$(ip route show default 0.0.0.0/0 2>/dev/null | awk '{print $3; exit}')"
  if [[ -n "$IFACE" ]]; then
    CIDR="$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')"
  fi

  if [[ -z "$IFACE" || -z "$CIDR" || -z "$GW" ]]; then
    return 1
  fi
  return 0
}

write_bootos_net_profile() {
  local out="${SHARED_DIR}/bootos_net.env"
  if detect_main_net; then
    cat > "$out" <<EOFNET
IFACE="${IFACE}"
CIDR="${CIDR}"
GW="${GW}"
EOFNET
    sync
    log "Boot-OS Netzprofil aktualisiert: IFACE=$IFACE CIDR=$CIDR GW=$GW"
  else
    log "WARN: Konnte Main-OS Netzprofil nicht ermitteln (bootos_net.env unverändert)."
  fi
}

enable_sd_boot() {
  mkdir -p "$SD_BOOT_MNT"
  local sd_boot_dev
  sd_boot_dev="$(lsblk -rpno NAME,FSTYPE | awk '$2=="vfat" && $1 ~ /\/dev\/mmcblk[0-9]+p[0-9]+$/ {print $1}' | head -n1)"
  [[ -n "$sd_boot_dev" ]] || { log "ERROR: No SD boot partition found."; return 1; }

  mount "$sd_boot_dev" "$SD_BOOT_MNT"
  local f="${SD_BOOT_MNT}/start4.elf"
  local fd="${SD_BOOT_MNT}/start4.elf.disabled"

  if [[ -f "$fd" ]]; then
    mv "$fd" "$f"
    log "SD boot enabled (start4.elf)."
  else
    log "SD boot already enabled."
  fi

  sync
  umount "$SD_BOOT_MNT"
}

strip_mainos_tag() { echo "$1" | sed -E 's/\[MAIN-OS\]//Ig'; }
normalize_prefix_trailing_underscores() { echo "$1" | sed -E 's/[[:space:]]+//g; s/_+$//'; }

run_sdimage_job() {

local LOG_FILE="${SHARED_DIR}/sdimage.log"

log_sd() {
  local msg="[$(date '+%F %T')] [sdimage] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

# optional: Log rotieren
rotate_sd_log() {
  local keep=5
  [[ -f "${LOG_FILE}.${keep}" ]] && rm -f "${LOG_FILE}.${keep}"
  for ((i=keep-1; i>=1; i--)); do
    [[ -f "${LOG_FILE}.${i}" ]] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
  done
  [[ -f "$LOG_FILE" ]] && mv -f "$LOG_FILE" "${LOG_FILE}.1"
}
rotate_sd_log

  local req_file="$1" flag_file="$2"
  local start_ts end_ts dur dur_str end_human
  start_ts="$(date +%s)"

  write_flag "$flag_file" "running"
  load_req_env "$req_file"

  local NODE; NODE="$(node_name)"

  local BACKUP_DIR="${BACKUP_DIR:-/mnt/syno-backup}"
  local IMAGE_PREFIX="${IMAGE_PREFIX:-raspi-}"
  local RETENTION_COUNT="${RETENTION_COUNT:-3}"

  local CIFS_SHARE="${CIFS_SHARE:-}"
  local CIFS_USER="${CIFS_USER:-User}"
  local CIFS_DOMAIN="${CIFS_DOMAIN:-WORKGROUP}"
  local CIFS_PASS="${CIFS_PASS:-}"
  local CIFS_UID="${CIFS_UID:-1000}"
  local CIFS_GID="${CIFS_GID:-1000}"

  local MODE="${MODE:-no-health}"
  local DRY_RUN=false
  [[ "$MODE" == "dry-run" ]] && DRY_RUN=true

  IMAGE_PREFIX="$(strip_mainos_tag "$IMAGE_PREFIX")"
  IMAGE_PREFIX="$(normalize_prefix_trailing_underscores "$IMAGE_PREFIX")"
  IMAGE_PREFIX="${IMAGE_PREFIX}_${BOOT_OS_TAG}_"

  rm -f "$SD_STATUS_ENV" "$SD_STATUS_JSON" 2>/dev/null || true

  local SD_DEV
  SD_DEV="$(lsblk -rpno NAME,TYPE | awk '$2=="disk" && $1 ~ /\/dev\/mmcblk[0-9]+$/ {print $1}' | head -n1)"
  [[ -n "$SD_DEV" ]] || { write_flag "$flag_file" "failed"; return 1; }

  local ZIP_CMD=""
  if command -v pigz >/dev/null 2>&1; then ZIP_CMD="pigz"
  elif command -v gzip >/dev/null 2>&1; then ZIP_CMD="gzip"
  else write_flag "$flag_file" "failed"; return 1
  fi

  mkdir -p "$BACKUP_DIR"
  if ! mountpoint -q "$BACKUP_DIR"; then
    [[ -n "$CIFS_SHARE" && -n "$CIFS_PASS" ]] || { write_flag "$flag_file" "failed"; return 1; }
    local opts="username=${CIFS_USER},password=${CIFS_PASS},domain=${CIFS_DOMAIN},uid=${CIFS_UID},gid=${CIFS_GID},iocharset=utf8,vers=3.0,_netdev"
    mount -t cifs "$CIFS_SHARE" "$BACKUP_DIR" -o "$opts" || { write_flag "$flag_file" "failed"; return 1; }
  fi

  local date_str image_name image_path
  date_str="$(date +%F_%H%M)"
  image_name="${IMAGE_PREFIX}${date_str}.img.gz"
  image_path="${BACKUP_DIR}/${image_name}"

  notify_gotify "SD-Backup startet (${NODE})" \ 
"Modus: ${MODE}
Quelle: ${SD_DEV}
Ziel: ${CIFS_SHARE}/${image_name}" 4

log_sd "SD-Backup startet (${NODE})" \ 
"Modus: ${MODE}
Quelle: ${SD_DEV}
Ziel: ${CIFS_SHARE}/${image_name}"

  if [[ "${MQTT_ENABLED:-false}" == "true" ]]; then
    local base="${MQTT_TOPIC_PREFIX:-pi-backups}/${NODE}"
    mqtt_publish_retained "${base}/sdimage/status" "{\"phase\":\"starting\",\"mode\":\"${MODE}\",\"image\":\"${image_name}\"}"
  fi

  if $DRY_RUN; then
    sleep 2
  else
    set +e
    dd if="$SD_DEV" bs=4M status=progress | "$ZIP_CMD" > "$image_path"
    local rc=$?
    set -e
    if (( rc != 0 )); then
      umount "$BACKUP_DIR" 2>/dev/null || true
      write_flag "$flag_file" "failed"
      notify_gotify "SD-Backup FEHLER (${NODE})" \
"dd/${ZIP_CMD} fehlgeschlagen (rc=${rc})
Image: ${CIFS_SHARE}/${image_name}" 8

log_sd "SD-Backup FEHLER (${NODE})" \
"dd/${ZIP_CMD} fehlgeschlagen (rc=${rc})
Image: ${CIFS_SHARE}/${image_name}"

      return 1
    fi
    sync
  fi

  umount "$BACKUP_DIR" 2>/dev/null || true
  end_ts="$(date +%s)"
  dur=$(( end_ts - start_ts ))
  dur_str="$(format_duration "$dur")"
  end_human="$(date '+%d.%m.%Y %H:%M')"

  {
    echo "STATE=success"
    echo "MODE=${MODE}"
    echo "FINISHED_AT=\"${end_human}\""
    echo "DURATION=\"${dur_str}\""
    echo "SECONDS=${dur}"
    echo "IMAGE=\"${image_name}\""
  } > "$SD_STATUS_ENV" || true

    log_sd "STATE=success"
    log_sd "MODE=${MODE}"
    log_sd "FINISHED_AT=\"${end_human}\""
    log_sd "DURATION=\"${dur_str}\""
    log_sd "SECONDS=${dur}"
    log_sd "IMAGE=\"${image_name}\""

  write_flag "$flag_file" "success"

  notify_gotify "SD-Backup fertig (${NODE})" \
"Modus: ${MODE}
Dauer: ${dur_str}
Fertig: ${end_human}
Image: ${CIFS_SHARE}/${image_name}" 5

log_sd "SD-Backup fertig (${NODE})" \
"Modus: ${MODE}
Dauer: ${dur_str}
Fertig: ${end_human}
Image: ${CIFS_SHARE}/${image_name}"
}



handle_completed_job() {
  local kind="$1" flag="$2" req="$3" status_env="$4"
  local st; st="$(flag_state "$flag")"
  [[ "$st" == "success" || "$st" == "failed" || "$st" == "unhealthy" ]] || return 0

  [[ -f "$req" ]] && load_req_env "$req"
  local NODE; NODE="$(node_name)"

  local finished_at duration mode image reason exit_code
  finished_at=""; duration=""; mode=""; image=""; reason=""; exit_code=""
  if [[ -f "$status_env" ]]; then
    # shellcheck disable=SC1090
    source "$status_env" 2>/dev/null || true
    finished_at="${FINISHED_AT:-}"
    duration="${DURATION:-}"
    mode="${MODE:-}"
    image="${IMAGE:-}"
    reason="${REASON:-}"
    exit_code="${EXIT_CODE:-}"
  fi

  local title_prefix="SD-Backup"
  [[ "$kind" == "usb" ]] && title_prefix="USB-Backup"

  local prio=5
  [[ "$st" != "success" ]] && prio=8

  local image_line=""
  if [[ -n "${CIFS_SHARE:-}" && -n "$image" ]]; then
    image_line="Image: ${CIFS_SHARE}/${image}"
  elif [[ -n "$image" ]]; then
    image_line="Image: ${image}"
  fi

  local msg
  msg="State: ${st}"

  [[ -n "$mode" ]]       && msg+=$'\n'"Modus: ${mode}"
  [[ -n "$duration" ]]   && msg+=$'\n'"Dauer: ${duration}"
  [[ -n "$finished_at" ]]&& msg+=$'\n'"Fertig: ${finished_at}"
  [[ -n "$reason" ]]     && msg+=$'\n'"Reason: ${reason}"
  [[ -n "$exit_code" ]]  && msg+=$'\n'"Exit: ${exit_code}"

  if [[ -n "${CIFS_SHARE:-}" && -n "$image" ]]; then
    msg+=$'\n'"Image: ${CIFS_SHARE}/${image}"
  elif [[ -n "$image" ]]; then
    msg+=$'\n'"Image: ${image}"
  fi

  notify_gotify "${title_prefix} abgeschlossen (${NODE})" "$msg" "$prio"

  rm -f "$flag" 2>/dev/null || true
  if [[ "${CLEANUP_REQUEST_ON_COMPLETE}" == "true" ]]; then
    rm -f "$req" 2>/dev/null || true
  fi
  sync
}

handle_pending_usb_job() {
  local st; st="$(flag_state "$BACKUP_FLAG")"
  [[ "$st" == "pending" && -f "$BACKUP_REQ" ]] || return 0

  load_req_env "$BACKUP_REQ"
  local NODE; NODE="$(node_name)"
  local MODE="${MODE:-no-health}"

  local now_ts; now_ts="$(date +%s)"
  if [[ -f "$GUARD_FILE" ]]; then
    local last_ts diff
    last_ts="$(cat "$GUARD_FILE" 2>/dev/null || echo 0)"
    if [[ "$last_ts" =~ ^[0-9]+$ ]]; then
      diff=$(( now_ts - last_ts ))
      (( diff < MIN_REBOOT_INTERVAL_SEC )) && return 0
    fi
  fi
  echo "$now_ts" > "$GUARD_FILE" || true

  write_flag "$BACKUP_FLAG" "running"

  notify_gotify "USB-Backup startet (${NODE})" \
"Modus: ${MODE}
Wechsle in ${BOOT_OS_TAG} und starte Backup..." 4

  write_bootos_net_profile || true
  enable_sd_boot || true
  sync
  sleep 2
  reboot || /usr/sbin/reboot || /sbin/reboot
  exit 0
}

log "Start, SHARED_DIR=${SHARED_DIR}"
while true; do
  handle_completed_job "sd"  "$SD_FLAG"     "$SD_REQ"     "$SD_STATUS_ENV"
  handle_completed_job "usb" "$BACKUP_FLAG" "$BACKUP_REQ" "$BACKUP_STATUS_ENV"

  sd_state="$(flag_state "$SD_FLAG")"
  if [[ "$sd_state" == "pending" && -f "$SD_REQ" ]]; then
    log "SD job pending -> run locally"
    run_sdimage_job "$SD_REQ" "$SD_FLAG" || true
    sleep 2
    continue
  fi

  handle_pending_usb_job
  sleep 3
done
EOF

  sed -i 's/\r$//' "$ORCH_PATH"
  chown root:root "$ORCH_PATH"
  chmod 755 "$ORCH_PATH"
}

write_service() {
  echo "[setup] Schreibe systemd Service nach ${SERVICE_PATH}..."
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Pi Backup Orchestrator (Main-OS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ORCH_PATH}
Restart=always
RestartSec=3

Environment=SHARED_DIR=/backupos_shared

[Install]
WantedBy=multi-user.target
EOF
}

disable_old_units() {
  for u in "${OLD_UNITS[@]}"; do
    if systemctl list-unit-files | grep -q "^${u}"; then
      echo "[setup] Deaktiviere alte Unit: $u"
      systemctl disable --now "$u" || true
      rm -f "/etc/systemd/system/${u}" "/etc/systemd/system/multi-user.target.wants/${u}" || true
    fi
  done
}

enable_service() {
  echo "[setup] systemd reload + enable/start..."
  systemctl daemon-reload
  systemctl enable --now pi-backup-orchestrator.service
  systemctl reset-failed || true
  systemctl status pi-backup-orchestrator.service --no-pager || true
}

main() {
  need_root
  install_deps
  setup_backup_shared_mount_mainos
  init_bootos_net_env_mainos
  write_orchestrator
  write_service
  disable_old_units
  ensure_bootorder_allows_sd
  enable_service
  echo "[setup] Fertig."
  echo "Logs: journalctl -u pi-backup-orchestrator.service -f"
}

main "$@"
