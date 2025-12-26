#!/usr/bin/env bash
set -euo pipefail

SHARED_DIR="/backupos_shared"

FLAG_FILE="${SHARED_DIR}/backup.flag"
REQ_FILE="${SHARED_DIR}/backup_request.env"
GUARD_FILE="${SHARED_DIR}/last_host_reboot.ts"

MIN_REBOOT_INTERVAL_SEC=300

EEPROM_SWITCH_BIN="/usr/local/sbin/pi-eeprom-bootorder.sh"

echo "[watcher] Starte Reboot-Watcher, SHARED_DIR=${SHARED_DIR}"

while true; do
  if [[ -f "$FLAG_FILE" && -f "$REQ_FILE" ]]; then
    now_ts=$(date +%s)

    if [[ -f "$GUARD_FILE" ]]; then
      last_ts=$(cat "$GUARD_FILE" 2>/dev/null || echo 0)
      if [[ "$last_ts" =~ ^[0-9]+$ ]]; then
        diff=$(( now_ts - last_ts ))
        if (( diff < MIN_REBOOT_INTERVAL_SEC )); then
          echo "[watcher] WARN: Reboot vor ${diff}s – Bootloop-Schutz aktiv."
          sleep 5
          continue
        fi
      fi
    fi

    echo "[watcher] Backup-Request gefunden → Switch EEPROM auf SD-first → Reboot Host"
    echo "$now_ts" > "$GUARD_FILE" || true

    # Flag vor Reboot löschen (Request bleibt!)
    rm -f "$FLAG_FILE" || true
    sync
    sleep 1


    sync
    sleep 2

    reboot || /usr/sbin/reboot || /sbin/reboot
    exit 0
  fi

  sleep 5
done
