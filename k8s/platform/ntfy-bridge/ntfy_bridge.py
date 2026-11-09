"""ntfy-bridge: turns Alertmanager webhooks into ntfy phone notifications.

Alertmanager has no ntfy receiver, and its webhook JSON would arrive on the phone as raw JSON. This
reads each webhook and publishes one readable message per alert group to ntfy (JSON publish, so
titles can hold any text). Only Alertmanager may call it (NetworkPolicy); it may only reach HTTPS.

    POST /alert     Alertmanager webhook (v4)
    GET  /healthz

Settings (secret ntfy, made by `make alerts-topic`): NTFY_TOPIC, optional NTFY_SERVER
(default https://ntfy.sh) and NTFY_TOKEN. Standard library only.
"""
import json
import os
import signal
import urllib.request
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVER = os.getenv("NTFY_SERVER", "https://ntfy.sh").rstrip("/")
TOPIC = os.getenv("NTFY_TOPIC", "")
TOKEN = os.getenv("NTFY_TOKEN", "")
CLICK = os.getenv("CLICK_URL", "")

# severity -> (ntfy priority 1-5, tag shown as an emoji)
LEVEL = {"critical": (5, "rotating_light"), "warning": (4, "warning"), "info": (3, "information_source")}


def log(event: str, **fields) -> None:
    print(json.dumps({"ts": datetime.now(UTC).isoformat(timespec="seconds"), "event": event, **fields}), flush=True)


def message(group: dict) -> dict:
    alerts = group.get("alerts", [])
    firing = [a for a in alerts if a.get("status") == "firing"]
    resolved = not firing
    shown = alerts if resolved else firing
    labels = group.get("commonLabels", {})
    name = labels.get("alertname") or "Alert"
    severity = labels.get("severity", "warning")
    prio, tag = LEVEL.get(severity, LEVEL["warning"])
    if resolved:
        title, prio, tags = f"Resolved: {name}", 2, ["white_check_mark"]
    else:
        title, tags = f"{severity.upper()}: {name}" + (f" ({len(firing)})" if len(firing) > 1 else ""), [tag]
    lines = []
    for a in shown[:5]:
        ann = a.get("annotations", {})
        lines.append(ann.get("summary") or a.get("labels", {}).get("alertname", ""))
        if not resolved and ann.get("description"):
            lines.append("-> " + ann["description"])
    if len(shown) > 5:
        lines.append(f"... and {len(shown) - 5} more")
    msg = {"topic": TOPIC, "title": title[:120], "message": "\n".join(lines)[:3500] or title,
           "priority": prio, "tags": tags}
    if CLICK:
        msg["click"] = CLICK
    return msg


def publish(msg: dict) -> int:
    headers = {"Content-Type": "application/json"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    req = urllib.request.Request(SERVER, data=json.dumps(msg).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status


class Handler(BaseHTTPRequestHandler):
    server_version = "ntfy-bridge"

    def reply(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200, {"ok": bool(TOPIC)}) if self.path == "/healthz" else self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/alert":
            return self.reply(404, {"error": "not found"})
        try:
            length = min(int(self.headers.get("Content-Length") or 0), 512 * 1024)
            group = json.loads(self.rfile.read(length))
            msg = message(group)
        except (ValueError, AttributeError) as exc:
            return self.reply(400, {"error": f"bad webhook: {exc}"[:200]})
        if not TOPIC:
            log("dropped_no_topic", title=msg["title"])
            return self.reply(503, {"error": "no ntfy topic set"})
        try:
            status = publish(msg)
            log("sent", title=msg["title"], priority=msg["priority"], ntfy_status=status)
            self.reply(200, {"sent": True})
        except Exception as exc:  # noqa: BLE001 — a 5xx makes Alertmanager retry
            log("send_failed", title=msg["title"], error=str(exc)[:200])
            self.reply(502, {"error": "ntfy unreachable"})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    log("start", server=SERVER, topic_set=bool(TOPIC))
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
