"""QwenOps waker, on the Raspberry Pi gateway (pi/setup.sh installs it).

nginx on the Pi passes every connection straight through to the server. When the server doesn't answer
(asleep), nginx falls back to a small local site that ends up here:

    GET  <any page>     "Waking up..." page; also sends the magic packet
    POST /api/wake      sends the magic packet (what the chat page calls)
    GET  /api/status    {"state": "waking"} until the server's /api/readyz answers, then "ready"

It also watches the server (every 30 s) and sends urgent ntfy alerts when it is down without having
announced a sleep, or doesn't wake when expected; "Server is back" when it returns. The server announces
planned sleeps on a second port, LAN-facing, with a shared token:

    POST :8082/sleeping {"until": <unix time>, "reason": "..."}   header X-Token
    GET  :8082/watch    what the watcher sees (no secrets)

Magic packets are rate-limited. The readiness check uses /api/readyz, which the server's idle timer
ignores, so the Pi never keeps the server awake. Standard library only.
"""
import hmac
import json
import os
import signal
import socket
import ssl
import threading
import time
import urllib.request
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SERVER_IP = os.environ["SERVER_IP"]
SERVER_MAC = os.environ["SERVER_MAC"]
BROADCAST = os.getenv("BROADCAST", "255.255.255.255")
CHECK_HOST = os.getenv("CHECK_HOST", "chatbot.local")      # certificate name for the readiness check
CA_FILE = os.getenv("CA_FILE", "/etc/qwenops-gateway/ca.crt")
PAGE = Path(__file__).with_name("waking.html").read_bytes()
WAKE_EVERY = 10.0              # at most one magic packet per 10 s
SLEEP_TOKEN = os.getenv("SLEEP_TOKEN", "")
NTFY_TOPIC = os.getenv("NTFY_TOPIC", "")
NTFY_SERVER = os.getenv("NTFY_SERVER", "https://ntfy.sh").rstrip("/")
STATE_FILE = Path(os.getenv("STATE_DIRECTORY", "/tmp")) / "watch.json"
WATCH_EVERY = 30               # seconds between checks
DOWN_AFTER = int(os.getenv("DOWN_AFTER_SECONDS", "180"))   # unannounced: alert after 3 min down
WAKE_GRACE = 600               # announced sleep: alert if still down 10 min after the planned wake
VISIT_GRACE = 300              # a visit sent the magic packet: alert if still down 5 min later
_lock = threading.Lock()
_last_wake = 0.0
_ready_cache: tuple[float, bool] = (0.0, False)


def log(event: str, **fields) -> None:
    print(json.dumps({"ts": datetime.now(UTC).isoformat(timespec="seconds"), "event": event, **fields}), flush=True)


def magic_packet(mac: str) -> bytes:
    raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
    if len(raw) != 6:
        raise ValueError("bad MAC")
    return b"\xff" * 6 + raw * 16


def wake(reason: str) -> bool:
    """Send the magic packet (to the subnet broadcast and the global one, port 9). False = rate-limited."""
    global _last_wake
    with _lock:
        now = time.monotonic()
        if now - _last_wake < WAKE_EVERY:
            return False
        _last_wake = now
    pkt = magic_packet(SERVER_MAC)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for addr in {BROADCAST, "255.255.255.255"}:
            s.sendto(pkt, (addr, 9))
    log("magic_packet_sent", mac=SERVER_MAC, reason=reason)
    watch.visit_woke(time.time())
    return True


class Watch:
    """Decides when "the server is down" is news. observe() returns alerts to send (title, text, priority)."""

    def __init__(self):
        self.up: bool | None = None          # None until the first check
        self.down_since: float | None = None
        self.alerted = False
        self.asleep_until = 0.0              # announced sleep (or maintenance) ends at this time
        self.reason = ""
        self.woken_at: float | None = None   # a visit sent the magic packet at this time

    def announce(self, until: float, reason: str) -> None:
        self.asleep_until, self.reason = until, reason

    def visit_woke(self, now: float) -> None:
        if self.up is False and self.woken_at is None:
            self.woken_at = now

    def observe(self, up: bool, now: float) -> list[tuple[str, str, int]]:
        if up:
            out = []
            if self.alerted and self.down_since:
                mins = max(1, round((now - self.down_since) / 60))
                out.append(("Server is back", f"The home server answers again after about {mins} min.", 3))
            self.up, self.down_since, self.alerted, self.woken_at = True, None, False, None
            self.asleep_until, self.reason = 0.0, ""
            return out
        if self.down_since is None:
            self.down_since = now
        self.up = False
        if self.alerted:
            return []
        if self.woken_at is not None and now - self.woken_at >= VISIT_GRACE:
            self.alerted = True
            text = ("Someone opened the site and the Pi sent the wake packet 5 minutes ago, but the server "
                    "still doesn't answer. Check its power and cable; press the power button if needed.")
            return [("Server didn't wake after a visit", text, 5)]
        if self.asleep_until:
            if now >= self.asleep_until + WAKE_GRACE:
                self.alerted = True
                text = (f"It went to sleep ({self.reason}) and should have woken by "
                        f"{time.strftime('%H:%M', time.localtime(self.asleep_until))}, but it doesn't answer. "
                        "Try your Wake-on-LAN app or the power button.")
                return [("Server didn't wake on schedule", text, 5)]
            return []
        if now - self.down_since >= DOWN_AFTER:
            self.alerted = True
            text = (f"The home server stopped answering {round((now - self.down_since) / 60)} min ago without "
                    "announcing a sleep: power cut, crash or network problem. The site is down.")
            return [("Server is down (not asleep)", text, 5)]
        return []

    def save(self) -> None:
        try:
            STATE_FILE.write_text(json.dumps({"asleep_until": self.asleep_until, "reason": self.reason}))
        except OSError:
            pass

    def load(self) -> None:
        try:
            d = json.loads(STATE_FILE.read_text())
            if d.get("asleep_until", 0) > time.time() - WAKE_GRACE:
                self.announce(float(d["asleep_until"]), str(d.get("reason", "")))
        except (OSError, ValueError, KeyError):
            pass


watch = Watch()


def notify(title: str, text: str, priority: int) -> None:
    log("alert", title=title, priority=priority)
    if not NTFY_TOPIC:
        return
    tags = ["white_check_mark"] if priority <= 3 else ["rotating_light"]
    body = json.dumps({"topic": NTFY_TOPIC, "title": title, "message": text, "priority": priority, "tags": tags})
    try:
        req = urllib.request.Request(NTFY_SERVER, data=body.encode(), headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10).close()
    except OSError as exc:
        log("alert_failed", error=str(exc)[:200])


def server_answers() -> bool:
    """Host-level: does anything accept a connection on the server's HTTPS port?"""
    try:
        with socket.create_connection((SERVER_IP, 443), timeout=3):
            return True
    except OSError:
        return False


def watch_loop() -> None:
    watch.load()
    while True:
        up = server_answers()
        before = watch.up
        for title, text, prio in watch.observe(up, time.time()):
            notify(title, text, prio)
        if before is not up:
            log("server_" + ("up" if up else "down"), announced_sleep=bool(watch.asleep_until), reason=watch.reason)
        time.sleep(WATCH_EVERY)


def server_ready() -> bool:
    """True if the server's chat-api answers /api/readyz over HTTPS (checked against the home CA)."""
    global _ready_cache
    at, ok = _ready_cache
    if time.monotonic() - at < 2:
        return ok
    ok = False
    try:
        ctx = ssl.create_default_context(cafile=CA_FILE)
        with socket.create_connection((SERVER_IP, 443), timeout=2) as raw, \
                ctx.wrap_socket(raw, server_hostname=CHECK_HOST) as tls:
            tls.settimeout(3)
            tls.sendall(f"GET /api/readyz HTTP/1.1\r\nHost: {CHECK_HOST}\r\nConnection: close\r\n\r\n".encode())
            ok = tls.recv(64).startswith(b"HTTP/1.1 200")
    except OSError:
        ok = False
    _ready_cache = (time.monotonic(), ok)
    return ok


class Handler(BaseHTTPRequestHandler):
    server_version = "qwenops-waker"

    def send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def json(self, code: int, obj: dict) -> None:
        self.send(code, json.dumps(obj).encode(), "application/json")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/status":
            return self.json(200, {"state": "ready" if server_ready() else "waking"})
        if path.startswith("/api/"):
            wake("api call while asleep")
            return self.json(503, {"detail": "The server is waking up. Try again in a minute."})
        if path in ("/favicon.ico", "/robots.txt"):
            return self.send(404, b"", "text/plain")
        wake("page opened")
        self.send(200, PAGE, "text/html; charset=utf-8")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/wake":
            sent = wake("wake button")
            return self.json(202, {"accepted": True, "sent": sent})
        wake("api call while asleep")
        self.json(503, {"detail": "The server is waking up. Try again in a minute."})

    def log_message(self, fmt, *args):
        pass


class LanHandler(BaseHTTPRequestHandler):
    """Port 8082 on the LAN: the server announces planned sleeps here."""
    server_version = "qwenops-waker"
    send = Handler.send
    json = Handler.json

    def do_GET(self):
        if self.path != "/watch":
            return self.json(404, {"error": "not found"})
        now = time.time()
        self.json(200, {"server": {None: "unknown", True: "up", False: "down"}[watch.up],
                        "down_for_s": round(now - watch.down_since) if watch.down_since else 0,
                        "asleep_until": watch.asleep_until or None, "reason": watch.reason or None,
                        "alerted": watch.alerted, "alerts_to_phone": bool(NTFY_TOPIC)})

    def do_POST(self):
        if self.path != "/sleeping":
            return self.json(404, {"error": "not found"})
        token = self.headers.get("X-Token", "")
        if not SLEEP_TOKEN or not hmac.compare_digest(token.encode(), SLEEP_TOKEN.encode()):
            log("sleep_notice_denied")
            return self.json(401, {"error": "bad token"})
        try:
            d = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 1024)) or b"{}")
            until, reason = float(d["until"]), str(d.get("reason", "sleep"))[:60]
        except (ValueError, KeyError, TypeError):
            return self.json(400, {"error": "need {until, reason}"})
        if not time.time() - 60 <= until <= time.time() + 3 * 86400:
            return self.json(400, {"error": "until must be within the next 3 days"})
        watch.announce(until, reason)
        watch.save()
        log("sleep_announced", until=time.strftime("%Y-%m-%d %H:%M", time.localtime(until)), reason=reason)
        self.json(202, {"accepted": True})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    magic_packet(SERVER_MAC)   # fail at start on a bad MAC
    log("start", server=SERVER_IP, mac=SERVER_MAC, broadcast=BROADCAST, alerts=bool(NTFY_TOPIC),
        sleep_notices=bool(SLEEP_TOKEN))
    threading.Thread(target=watch_loop, daemon=True).start()
    threading.Thread(target=ThreadingHTTPServer(("0.0.0.0", 8082), LanHandler).serve_forever, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", 8081), Handler).serve_forever()
