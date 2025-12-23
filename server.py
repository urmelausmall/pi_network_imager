#!/usr/bin/env python3
import os
import json
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

HOST = "0.0.0.0"
PORT = int(os.getenv("API_PORT", "8080"))

# Gemeinsames Verzeichnis zum Backup-OS
SHARED_DIR = os.getenv("BACKUP_SHARED_DIR", "/backupos_shared")

# Optional: Name des Hosts/Nodes
BACKUP_NODE_NAME = os.getenv("BACKUP_NODE_NAME", "")

# === Helper: sicheres JSON-Senden (BrokenPipe abfangen) =======================

class Handler(BaseHTTPRequestHandler):
    def _send_json(self, code, payload):
        try:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            # Client hat Verbindung abgebrochen (z.B. durch Reboot) → ignoriere
            pass
        except OSError:
            # Socket ist weg → auch ignorieren
            pass

    def log_message(self, format, *args):
        # optional: Standard-Logging von BaseHTTPRequestHandler unterdrücken
        print("%s - - [%s] %s" %
              (self.client_address[0],
               self.log_date_time_string(),
               format % args),
              flush=True)

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/backup":
            self._send_json(404, {"error": "not_found"})
            return

        # --- Mode & Zero-Fill aus Query / Body -------------------------------
        mode = None
        zero_fill = False

        qs = parse_qs(parsed.query)
        if "mode" in qs and qs["mode"]:
            mode = qs["mode"][0]

        if "zero_fill" in qs and qs["zero_fill"]:
            val = qs["zero_fill"][0].strip().lower()
            if val in ("1", "true", "yes", "on"):
                zero_fill = True
            elif val in ("0", "false", "no", "off"):
                zero_fill = False

        length = int(self.headers.get("Content-Length") or 0)
        if length > 0:
            body = self.rfile.read(length)
            try:
                data = json.loads(body.decode("utf-8"))
                if isinstance(data, dict):
                    if "mode" in data:
                        mode = data["mode"]
                    if "zero_fill" in data:
                        z = data["zero_fill"]
                        if isinstance(z, bool):
                            zero_fill = z
                        elif isinstance(z, str):
                            val = z.strip().lower()
                            if val in ("1", "true", "yes", "on"):
                                zero_fill = True
                            elif val in ("0", "false", "no", "off"):
                                zero_fill = False
                        elif isinstance(z, int):
                            zero_fill = (z != 0)
            except Exception:
                # Body kaputt → ignorieren, Query bleibt gültig
                pass

        if mode not in ("dry-run", "no-health", "with-health"):
            self._send_json(400, {
                "error": "invalid_mode",
                "allowed": ["dry-run", "no-health", "with-health"]
            })
            return

        # Shared-Dir prüfen
        if not os.path.isdir(SHARED_DIR):
            self._send_json(500, {
                "error": "shared_dir_missing",
                "details": f"{SHARED_DIR} existiert nicht (ist das BACKUP_SHARED Volume gemountet?)"
            })
            return

        # --- Backup-Job-Datei schreiben --------------------------------------
        try:
            os.makedirs(SHARED_DIR, exist_ok=True)
            request_path = os.path.join(SHARED_DIR, "backup_request.env")
            flag_path = os.path.join(SHARED_DIR, "backup.flag")

            # alte Status-Datei optional löschen (Backup-OS schreibt später neue)
            status_env = os.path.join(SHARED_DIR, "backup_status.env")
            status_json = os.path.join(SHARED_DIR, "backup_status.json")
            for p in (status_env, status_json):
                if os.path.exists(p):
                    os.remove(p)

            env_lines = []

            # Grund-Infos / Modus
            env_lines.append(f'MODE="{mode}"')
            env_lines.append(f'ZERO_FILL={"true" if zero_fill else "false"}')

            # Flag für Healthcheck im Backup-OS
            if mode == "with-health":
                env_lines.append('HEALTH_CHECK=true')
            else:
                env_lines.append('HEALTH_CHECK=false')

            # Node-Name, falls gesetzt
            if BACKUP_NODE_NAME:
                env_lines.append(f'BACKUP_NODE_NAME="{BACKUP_NODE_NAME}"')

            # Bestehende Env-Variablen durchreichen (wie im alten Container)
            passthrough_keys = [
                "IMAGE_PREFIX",
                "RETENTION_COUNT",
                "CIFS_SHARE",
                "CIFS_USER",
                "CIFS_DOMAIN",
                "CIFS_PASS",
                "CIFS_UID",
                "CIFS_GID",
                "GOTIFY_URL",
                "GOTIFY_TOKEN",
                "GOTIFY_ENABLED",
                "MQTT_ENABLED",
                "MQTT_HOST",
                "MQTT_PORT",
                "MQTT_USER",
                "MQTT_PASS",
                "MQTT_TLS",
                "MQTT_DISCOVERY_PREFIX",
                "MQTT_TOPIC_PREFIX",
                "BACKUP_SRC_HINT",      # z.B. LABEL=..., PARTUUID=..., DEVICE=/dev/sda
            ]

            for key in passthrough_keys:
                val = os.getenv(key)
                if val is not None:
                    # einfache Shell-Quote-Variante
                    safe = val.replace('"', '\\"')
                    env_lines.append(f'{key}="{safe}"')

            with open(request_path, "w", encoding="utf-8") as f:
                f.write("# Automatisch vom Haupt-OS-Backup-Container generiert\n")
                for line in env_lines:
                    f.write(line + "\n")

            # Flag anlegen → Backup-OS weiß: es gibt einen neuen Job
            with open(flag_path, "w", encoding="utf-8") as f:
                f.write("pending\n")

            print(
                f"[API] Backup-Job geschrieben: mode={mode}, ZERO_FILL={zero_fill}, request={request_path}",
                flush=True
            )

        except Exception as e:
            self._send_json(500, {
                "error": "write_failed",
                "details": str(e),
            })
            return

        # --- Antwort an Client schicken, bevor wir rebooten ------------------
        self._send_json(200, {
            "status": "backup_scheduled",
            "mode": mode,
            "zero_fill": zero_fill,
            "shared_dir": SHARED_DIR,
        })

        # --- Reboot im Hintergrund anstoßen ----------------------------------
        try:
            # Host rebooten – Container muss mit Privilegien laufen
            subprocess.Popen(["/sbin/reboot", "now"])
            print("[API] Reboot wurde angestoßen.", flush=True)
        except FileNotFoundError:
            print("[API] WARN: /sbin/reboot nicht gefunden – bitte auf dem Host prüfen.", flush=True)
        except Exception as e:
            print(f"[API] Reboot-Fehler: {e}", flush=True)


def main():
    server = HTTPServer((HOST, PORT), Handler)
    print(f"Backup API listening on {HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
