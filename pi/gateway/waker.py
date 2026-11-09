"""QwenOps waker, on the Raspberry Pi gateway (pi/setup.sh installs it).

nginx on the Pi passes every connection straight through to the server. When the server doesn't answer
(asleep), nginx falls back to a small local site that ends up here:

    GET  <any page>     "Waking up..." page; also sends the magic packet
    POST /api/wake      sends the magic packet (what the chat page calls)
    GET  /api/status    {"state": "waking"} until the server's /api/readyz answers, then "ready"

Magic packets are rate-limited. The readiness check uses /api/readyz, which the server's idle timer
ignores, so the Pi never keeps the server awake. Standard library only.
"""
import json
import os
import signal
import socket
import ssl
import threading
import time
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
    return True


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


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    magic_packet(SERVER_MAC)   # fail at start on a bad MAC
    log("start", server=SERVER_IP, mac=SERVER_MAC, broadcast=BROADCAST)
    ThreadingHTTPServer(("127.0.0.1", 8081), Handler).serve_forever()
