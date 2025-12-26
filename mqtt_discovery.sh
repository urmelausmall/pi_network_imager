#!/usr/bin/env bash
set -euo pipefail

MQTT_ENABLED="${MQTT_ENABLED:-false}"
MQTT_HOST="${MQTT_HOST:-mqtt}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
MQTT_TLS="${MQTT_TLS:-false}"

MQTT_DISCOVERY_PREFIX="${MQTT_DISCOVERY_PREFIX:-homeassistant}"
MQTT_TOPIC_PREFIX="${MQTT_TOPIC_PREFIX:-homelab/pi-backup}"
BACKUP_NODE_NAME="${BACKUP_NODE_NAME:-pi-node}"

[[ "$MQTT_ENABLED" == "true" ]] || exit 0

base_topic="${MQTT_TOPIC_PREFIX}/${BACKUP_NODE_NAME}"
disc_base="${MQTT_DISCOVERY_PREFIX}/sensor/${BACKUP_NODE_NAME}_backup"

args=( -h "$MQTT_HOST" -p "$MQTT_PORT" )
[[ -n "$MQTT_USER" ]] && args+=( -u "$MQTT_USER" )
[[ -n "$MQTT_PASS" ]] && args+=( -P "$MQTT_PASS" )
if [[ "${MQTT_TLS,,}" == "true" ]]; then
  args+=( --tls-version tlsv1.2 )
fi

# 1) Status-Sensor (phase aus status-JSON)
status_payload=$(cat <<EOF
{
  "name": "Backup Status ${BACKUP_NODE_NAME}",
  "uniq_id": "${BACKUP_NODE_NAME}_backup_status",
  "stat_t": "${base_topic}/status",
  "value_template": "{{ value_json.phase }}",
  "ic": "mdi:shield-sync",
  "dev": {
    "ids": ["${BACKUP_NODE_NAME}_backup"],
    "name": "Backup ${BACKUP_NODE_NAME}"
  }
}
EOF
)

mosquitto_pub "${args[@]}" \
  -t "${disc_base}_status/config" \
  -m "${status_payload}" \
  -r || true

# 2) Letzter Lauf (optional, liest last_run.json im Shared dir)
SHARED_DIR="${BACKUP_SHARED_DIR:-/backupos_shared}"
LAST_RUN_JSON="${SHARED_DIR}/last_run.json"

if [[ -f "$LAST_RUN_JSON" ]]; then
  last_payload=$(cat <<EOF
{
  "name": "Backup Last Run ${BACKUP_NODE_NAME}",
  "uniq_id": "${BACKUP_NODE_NAME}_backup_last_run",
  "stat_t": "${base_topic}/status",
  "value_template": "{{ value_json.finished_at if value_json.finished_at is defined else '' }}",
  "ic": "mdi:clock-check-outline",
  "dev": {
    "ids": ["${BACKUP_NODE_NAME}_backup"],
    "name": "Backup ${BACKUP_NODE_NAME}"
  }
}
EOF
)
  mosquitto_pub "${args[@]}" \
    -t "${disc_base}_last_run/config" \
    -m "${last_payload}" \
    -r || true
fi
