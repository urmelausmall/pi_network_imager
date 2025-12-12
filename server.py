#!/usr/bin/env python3
import os
import json
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
from urllib.request import Request, urlopen
from urllib.error import URLError

HOST = "0.0.0.0"
PORT = int(os.getenv("API_PORT", "8080"))

GOTIFY_URL = os.getenv("GOTIFY_URL", "")
GOTIFY_TOKEN = os.getenv("GOTIFY_TOKEN", "")
GOTIFY_ENABLED = os.getenv("GOTIFY_ENABLED", "true").lower() == "true"
IMAGE_PREFIX = os.getenv("IMAGE_PREFIX", "PI_IMAGE")

def send_gotify(title: str, message: str, priority: int = 5):
    if not GOTIFY_ENABLED or not GOTIFY_URL or not GOTIFY_TOKEN:
        return
    try:
        data = f"title={title}&message={message}&priority={priority}".encode("utf-8")
        url = GOTIFY_URL.rstrip("/") + f"/message?token={GOTIFY_TOKEN}"
        req = Request(url, data=data, method="POST")
        urlopen(req, timeout=5).read()
    except URLError:
        # Silent fail, wir wollen Backup nicht abbrechen, nur weil Gotify nicht erreichbar ist
        pass


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, code, payload):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode("utf-8"))

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/backup":
          self._send_json(404, {"error": "not_found"})
          return

        # Mode aus Query oder JSON-Body
        mode = None

        # >>> Zero-Fill-Flag, default: False
        zero_fill = False

        # Query-String: /backup?mode=dry-run&zero_fill=true
        qs = parse_qs(parsed.query)
        if "mode" in qs and qs["mode"]:
            mode = qs["mode"][0]

        # zero_fill aus Query übernehmen
        if "zero_fill" in qs and qs["zero_fill"]:
            val = qs["zero_fill"][0].strip().lower()
            if val in ("1", "true", "yes", "on"):
                zero_fill = True
            elif val in ("0", "false", "no", "off"):
                zero_fill = False

        # JSON-Body optional (kann mode UND zero_fill überschreiben)
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
                        # bool direkt
                        if isinstance(z, bool):
                            zero_fill = z
                        # string interpretieren
                        elif isinstance(z, str):
                            val = z.strip().lower()
                            if val in ("1", "true", "yes", "on"):
                                zero_fill = True
                            elif val in ("0", "false", "no", "off"):
                                zero_fill = False
                        # int interpretieren
                        elif isinstance(z, int):
                            zero_fill = (z != 0)
            except Exception:
                # Body kaputt? Ignorieren, Query-Parameter gelten weiter
                pass

        if mode not in ("dry-run", "no-health", "with-health"):
            self._send_json(400, {
                "error": "invalid_mode",
                "allowed": ["dry-run", "no-health", "with-health"]
            })
            return

        # passenden Command bauen
        cmd = ["./backup_sd.sh", "--non-interactive"]

        if mode == "dry-run":
            cmd += ["--dry-run", "--no-health-check"]
        elif mode == "no-health":
            cmd += ["--no-health-check"]
        elif mode == "with-health":
            cmd += ["--health-check"]

        # >>> Environment für den Prozess vorbereiten
        env = os.environ.copy()
        env["ZERO_FILL"] = "true" if zero_fill else "false"

        # Optional: kleine Debug-Info im Log
        print(f"[API] Starte Backup: mode={mode}, ZERO_FILL={env['ZERO_FILL']}", flush=True)

        # Gotify-Startmeldung
        #send_gotify(
        #    title=f"Backup Trigger ({mode})",
        #    message=(
        #        f"Backup-Container (Image: {IMAGE_PREFIX}) wurde gestartet "
        #        f"(Modus: {mode}, ZERO_FILL={env['ZERO_FILL']})."
        #    ),
        #    priority=4,
        #)

        try:
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,   # <<< HIER wichtig: angepasste Env übergeben
            )
            payload = {
                "mode": mode,
                "zero_fill": zero_fill,
                "returncode": proc.returncode,
                "stdout": proc.stdout,
                "stderr": proc.stderr,
            }
            code = 200 if proc.returncode == 0 else 500
            self._send_json(code, payload)
        except Exception as e:
            self._send_json(500, {"error": "execution_failed", "details": str(e)})


def main():
    server = HTTPServer((HOST, PORT), Handler)
    print(f"Backup API listening on {HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
