#!/usr/bin/env python3
import os
import json

from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

HOST = "0.0.0.0"
PORT = int(os.getenv("API_PORT", "8080"))

# Gemeinsames Verzeichnis zum Backup-OS
SHARED_DIR = os.getenv("BACKUP_SHARED_DIR", "/backupos_shared")

# Optional: Name des Hosts/Nodes
BACKUP_NODE_NAME = os.getenv("BACKUP_NODE_NAME", "")

# Suffix das an IMAGE_PREFIX angehängt wird (kannst du per ENV ändern)
BACKUP_OS_PREFIX_SUFFIX = os.getenv("BACKUP_OS_PREFIX_SUFFIX", "[MAIN-OS]")


def _to_bool(val, default=False):
    if val is None:
        return default
    if isinstance(val, bool):
        return val
    if isinstance(val, int):
        return (val != 0)
    if isinstance(val, str):
        v = val.strip().lower()
        if v in ("1", "true", "yes", "on"):
            return True
        if v in ("0", "false", "no", "off"):
            return False
    return default


def _shell_escape(val: str) -> str:
    """
    Minimal robustes Escaping für KEY="VALUE" ENV-Dateien:
    - Backslashes doppeln
    - Anführungszeichen escapen
    """
    s = str(val)
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _append_prefix_suffix(prefix: str, suffix: str) -> str:
    """
    Aus IMAGE_PREFIX + 'BACKUP-OS' wird:
      '<prefix>_BACKUP-OS_'
    Dabei werden doppelte Unterstriche vermieden.
    Hängt NICHT nochmal an, wenn es schon enthalten ist.
    """
    p = (prefix or "").strip()
    s = (suffix or "").strip()

    if not s:
        return p

    p_norm = p.rstrip("_")
    s_norm = s.strip("_")
    token = f"_{s_norm}_"

    # schon vorhanden? dann nicht nochmal anhängen
    if token in f"_{p_norm}_":
        return p if p.endswith("_") else (p + "_")

    if not p_norm:
        return f"{s_norm}_"

    return f"{p_norm}_{s_norm}_"


def _read_request(parsed, headers, rfile):
    """
    Liest Query + optionalen JSON Body.
    JSON überschreibt Query.
    """
    qs = parse_qs(parsed.query)

    mode = qs.get("mode", [None])[0]
    bos_maintance = _to_bool(qs.get("bos_maintance", [None])[0], default=False)
    bos_update = _to_bool(qs.get("bos_update", [None])[0], default=False)

    length = int(headers.get("Content-Length") or 0)
    if length > 0:
        body = rfile.read(length)
        try:
            data = json.loads(body.decode("utf-8"))
            if isinstance(data, dict):
                if "mode" in data:
                    mode = data["mode"]
                if "bos_maintance" in data:
                    bos_maintance = _to_bool(data["bos_maintance"], default=bos_maintance)
                if "bos_update" in data:
                    bos_update = _to_bool(data["bos_update"], default=bos_update)
        except Exception:
            pass

    return mode, bos_maintance, bos_update


def _ensure_shared_dir():
    if not os.path.isdir(SHARED_DIR):
        raise RuntimeError(f"{SHARED_DIR} existiert nicht (ist das BACKUP_SHARED Volume gemountet?)")
    os.makedirs(SHARED_DIR, exist_ok=True)


def _write_job_files(job_prefix: str, env_lines: list[str], status_files: tuple[str, str]):
    """
    job_prefix: "backup" oder "sdimage"
    status_files: ("<job>_status.env", "<job>_status.json")
    """
    request_path = os.path.join(SHARED_DIR, f"{job_prefix}_request.env")
    flag_path = os.path.join(SHARED_DIR, f"{job_prefix}.flag")

    # alte Status-Dateien löschen
    status_env = os.path.join(SHARED_DIR, status_files[0])
    status_json = os.path.join(SHARED_DIR, status_files[1])
    for p in (status_env, status_json):
        if os.path.exists(p):
            os.remove(p)

    with open(request_path, "w", encoding="utf-8") as f:
        f.write("# Automatisch vom Haupt-OS-Backup-Container generiert\n")
        for line in env_lines:
            f.write(line + "\n")

    # Flag anlegen → Backup-OS weiß: es gibt einen neuen Job
    with open(flag_path, "w", encoding="utf-8") as f:
        f.write("pending\n")

    return request_path, flag_path


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, code, payload):
        try:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, OSError):
            pass

    def log_message(self, format, *args):
        print(
            "%s - - [%s] %s"
            % (self.client_address[0], self.log_date_time_string(), format % args),
            flush=True
        )

    def do_POST(self):
        parsed = urlparse(self.path)

        # ----------------------------
        # Endpoints trennen
        # ----------------------------
        if parsed.path not in ("/backup", "/sdimage"):
            self._send_json(404, {"error": "not_found"})
            return

        # ----------------------------
        # Request lesen
        # ----------------------------
        mode, bos_maintance, bos_update = _read_request(parsed, self.headers, self.rfile)

        if mode not in ("dry-run", "no-health", "with-health"):
            self._send_json(400, {
                "error": "invalid_mode",
                "allowed": ["dry-run", "no-health", "with-health"]
            })
            return

        # Shared-Dir prüfen
        try:
            _ensure_shared_dir()
        except Exception as e:
            self._send_json(500, {"error": "shared_dir_missing", "details": str(e)})
            return

        # ----------------------------
        # Job-spezifisch bauen
        # ----------------------------
        try:
            passthrough_keys = [
                "IMAGE_PREFIX",
                "RETENTION_COUNT",
                "BACKUP_DIR",
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
                "BACKUP_SRC_HINT",
            ]

            existing = {}
            for key in passthrough_keys:
                val = os.getenv(key)
                if val is not None:
                    existing[key] = val

            # IMAGE_PREFIX erweitern => "<prefix>_BACKUP-OS_"
            if "IMAGE_PREFIX" in existing and str(existing["IMAGE_PREFIX"]).strip():
                existing["IMAGE_PREFIX"] = _append_prefix_suffix(
                    str(existing["IMAGE_PREFIX"]),
                    BACKUP_OS_PREFIX_SUFFIX
                )

            env_lines = []
            env_lines.append(f'MODE="{_shell_escape(mode)}"')
            env_lines.append(f'HEALTH_CHECK={"true" if mode == "with-health" else "false"}')
            env_lines.append(f'BOS_MAINTANCE={"true" if bos_maintance else "false"}')

            if BACKUP_NODE_NAME:
                env_lines.append(f'BACKUP_NODE_NAME="{_shell_escape(BACKUP_NODE_NAME)}"')

            for key, val in existing.items():
                env_lines.append(f'{key}="{_shell_escape(val)}"')

            if parsed.path == "/backup":
                # Normaler Job
                request_path, flag_path = _write_job_files(
                    job_prefix="backup",
                    env_lines=env_lines,
                    status_files=("backup_status.env", "backup_status.json")
                )

                print(
                    f"[API] Backup-Job geschrieben: mode={mode}, BOS_MAINTANCE={bos_maintance}, request={request_path}",
                    flush=True
                )

                self._send_json(200, {
                    "status": "backup_scheduled",
                    "mode": mode,
                    "bos_maintance": bos_maintance,
                    "shared_dir": SHARED_DIR,
                    "request": os.path.basename(request_path),
                    "flag": os.path.basename(flag_path),
                    "image_prefix_effective": existing.get("IMAGE_PREFIX"),
                })
                return

            # parsed.path == "/sdimage"
            # SD-Image Job (getrennte Dateien)
            request_path, flag_path = _write_job_files(
                job_prefix="sdimage",
                env_lines=env_lines,
                status_files=("sdimage_status.env", "sdimage_status.json")
            )

            print(
                f"[API] SD-Image-Job geschrieben: mode={mode}, BOS_MAINTANCE={bos_maintance}, request={request_path}",
                flush=True
            )

            self._send_json(200, {
                "status": "sdimage_scheduled",
                "mode": mode,
                "bos_maintance": bos_maintance,
                "shared_dir": SHARED_DIR,
                "request": os.path.basename(request_path),
                "flag": os.path.basename(flag_path),
                "image_prefix_effective": existing.get("IMAGE_PREFIX"),
            })

        except Exception as e:
            self._send_json(500, {"error": "write_failed", "details": str(e)})
            return


def main():
    server = HTTPServer((HOST, PORT), Handler)
    print(f"Backup API listening on {HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
