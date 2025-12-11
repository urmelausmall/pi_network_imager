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

    # Query-String: /backup?mode=dry-run
    qs = parse_qs(parsed.query)
    if "mode" in qs and qs["mode"]:
      mode = qs["mode"][0]

    # JSON-Body optional
    length = int(self.headers.get("Content-Length") or 0)
    if length > 0:
      body = self.rfile.read(length)
      try:
        data = json.loads(body.decode("utf-8"))
        if isinstance(data, dict) and "mode" in data:
          mode = data["mode"]
      except Exception:
        pass

    if mode not in ("dry-run", "no-health", "with-health"):
      self._send_json(400, {"error": "invalid_mode", "allowed": ["dry-run", "no-health", "with-health"]})
      return

    # passenden Command bauen
    cmd = ["./backup_sd.sh", "--non-interactive"]

    if mode == "dry-run":
      cmd += ["--dry-run", "--no-health-check"]
    elif mode == "no-health":
      cmd += ["--no-health-check"]
    elif mode == "with-health":
      cmd += ["--health-check"]

    # Gotify-Startmeldung
    send_gotify(
      title=f"Backup Trigger ({mode})",
      message=f"Backup-Container auf {os.uname().nodename} wurde gestartet (Modus: {mode}).",
      priority=4,
    )

    try:
      proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
      )
      payload = {
        "mode": mode,
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
