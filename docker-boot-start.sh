#!/usr/bin/env bash
set -euo pipefail

# ─── BASISPFAD ANPASSEN ───────────────────────────────────────────────────────
# Hier liegen im Container/Host die Marker-Dateien (per ENV überschreibbar):
MARKER_DIR="${MARKER_DIR:-/markers}"

DEPENDENCY_FILE="${DEPENDENCY_FILE:-$MARKER_DIR/dependencies.txt}"
PRIORITY_FILE="${PRIORITY_FILE:-$MARKER_DIR/first_boot_container.txt}"

# ─── GOTIFY (aus Umgebung übernehmen) ─────────────────────────────────────────
GOTIFY_URL="${GOTIFY_URL:-}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"
GOTIFY_ENABLED="${GOTIFY_ENABLED:-true}"

send_gotify_message() {
  local msg="$1"

  # Wenn Gotify global deaktiviert oder keine URL/TOKEN → nichts senden
  if [[ "$GOTIFY_ENABLED" != "true" ]]; then
    return 0
  fi
  if [[ -z "${GOTIFY_URL:-}" || -z "${GOTIFY_TOKEN:-}" ]]; then
    return 0
  fi

  # curl optional, aber sinnvoll
  if ! command -v curl &>/dev/null; then
    return 0
  fi

  curl -sS -X POST "${GOTIFY_URL%/}/message?token=${GOTIFY_TOKEN}" \
    -F "title=Docker Boot Orchestrator" \
    -F "message=${msg}" \
    -F "priority=5" \
    >/dev/null || true
}


# ─── Logging ─────────────────────────────────────────────────────────────────
log_messages="🚀 Docker-Start-Skript (Pi 4GB) gestartet\n\n"
log() {
  echo "$1"
  log_messages+="$1\n"
}

# ─── Timeouts & Delay ─────────────────────────────────────────────────────────
DEP_TIMEOUT=60
START_TEST_TIMEOUT=30
INTERVAL=2
MIN_DELAY=10

DOCKER_BIN="$(command -v docker || echo /usr/bin/docker)"

wait_for_container() {
  local c="$1" timeout="${2:-$START_TEST_TIMEOUT}" elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    local health status
    health=$($DOCKER_BIN inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo "")
    status=$($DOCKER_BIN inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "")
    if [ "$health" = "healthy" ] || { [ "$health" = "none" ] && [ "$status" = "running" ]; }; then
      return 0
    fi
    sleep $INTERVAL
    elapsed=$((elapsed + INTERVAL))
  done
  return 1
}

# ─── Dependencies einlesen ────────────────────────────────────────────────────
declare -A deps=()
if [ -f "$DEPENDENCY_FILE" ]; then
  log "🔗 Dependencies laden aus $DEPENDENCY_FILE:"
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    case "$l" in \#*) continue ;; esac
    name="$(echo "${l%%depends on*}" | xargs)"
    rest="${l#*depends on}"
    rest="$(echo "${rest//&/,}" | xargs)"
    IFS=',' read -ra arr <<< "$rest"
    deps["$name"]="${arr[*]}"
    log "  • $name:"
    for dep in "${arr[@]}"; do
      log "      - $dep"
    done
  done < "$DEPENDENCY_FILE"
  log ""
else
  log "ℹ️ Keine Dependency-Datei gefunden: $DEPENDENCY_FILE (ok, dann halt ohne)"
fi

# ─── Priorisierte Container ──────────────────────────────────────────────────
if [ ! -f "$PRIORITY_FILE" ]; then
  log "⚠️ Prioritäten-Datei fehlt: $PRIORITY_FILE"
  send_gotify_message "$(printf '%b' "$log_messages")"
  exit 1
fi

declare -a priority_containers=()
log "📋 Boot-Prioritäten aus $PRIORITY_FILE:"
while IFS= read -r l; do
  [ -z "$l" ] && continue
  case "$l" in \#*) continue ;; esac
  priority_containers+=("$(echo "$l" | xargs)")
  log "  - $l"
done < "$PRIORITY_FILE"
log ""

# ─── Start-Funktion mit Dependencies ─────────────────────────────────────────
start_with_deps() {
  local c="$1"
  log "▶️ Starte $c"

  IFS=' ' read -r -a arr <<< "${deps[$c]:-}"
  if [ ${#arr[@]} -gt 0 ]; then
    log "  Abhängigkeiten:"
    for dep in "${arr[@]}"; do
      log "    ├─ $dep"
      if wait_for_container "$dep" "$DEP_TIMEOUT"; then
        log "    │  ✓ ready"
      else
        log "    │  ✗ Timeout – starte $dep"
        $DOCKER_BIN start "$dep" >/dev/null 2>&1 || :
        if wait_for_container "$dep" "$START_TEST_TIMEOUT"; then
          log "    │  ✓ ready"
        else
          log "    │  ✗ unready"
        fi
      fi
    done
    log ""
  fi

  $DOCKER_BIN start "$c" >/dev/null 2>&1 || :
  if wait_for_container "$c"; then
    log "└─ ✓ $c läuft"
  else
    log "└─ ✗ $c unready"
  fi
  log "    ⏳ Warte $MIN_DELAY s"
  sleep $MIN_DELAY
  log ""
}

# ─── Priorisierte starten ─────────────────────────────────────────────────────
log "== 🚀 Starte priorisierte Container =="
for c in "${priority_containers[@]}"; do
  start_with_deps "$c"
done

# ─── Restliche Container ─────────────────────────────────────────────────────
log "== 🚀 Starte restliche Container =="
mapfile -t all_names < <($DOCKER_BIN ps -a --format '{{.Names}}')
for c in "${all_names[@]}"; do
  [[ " ${priority_containers[*]} " =~ " $c " ]] && continue
  start_with_deps "$c"
done

# ─── Abschluss ───────────────────────────────────────────────────────────────
log "✅ Alle Container gestartet"
send_gotify_message "$(printf '%b' "$log_messages")"
