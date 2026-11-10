"""Public chat (Phase 9b): only requests the Pi vouches for (edge secret) count as public. They get
stricter limits, are always guests (nothing stored, no database call) and reach only the chat paths."""
import json

import httpx
from fastapi.testclient import TestClient

from app import main

EDGE = "e" * 40


def _client(monkeypatch, secret=EDGE):
    main._hits.clear()
    monkeypatch.setattr(main.config, "EDGE_SECRET", secret)
    return TestClient(main.app)


def _public(ip="203.0.113.7", edge=EDGE):
    return {"X-QwenOps-Edge": edge, "X-QwenOps-Client": ip}


class NoDatabase:
    def connection(self, *a, **kw):
        raise AssertionError("public visitors must not touch the database")


def _fake_model(monkeypatch):
    def handler(req):
        if req.url.path == "/api/chat":
            body = json.loads(req.content)
            assert body["options"]["num_predict"] == main.config.PUBLIC_MAX_TOKENS
            lines = [{"message": {"content": "Hi"}}, {"message": {"content": "!"}, "done": True}]
            return httpx.Response(200, content="\n".join(json.dumps(x) for x in lines).encode())
        return httpx.Response(404)
    monkeypatch.setattr(main, "http", httpx.AsyncClient(base_url="http://ollama", transport=httpx.MockTransport(handler)))
    monkeypatch.setattr(main, "pool", NoDatabase())


def test_only_the_right_secret_makes_a_request_public(monkeypatch):
    c = _client(monkeypatch)
    from starlette.requests import Request
    def req(h):
        return Request({"type": "http", "headers": [(k.lower().encode(), v.encode()) for k, v in h.items()],
                        "client": ("10.42.0.9", 1), "path": "/", "query_string": b""})
    assert main.public_client(req(_public())) == "203.0.113.7"
    assert main.public_client(req(_public(edge="wrong"))) is None
    assert main.public_client(req({"X-QwenOps-Client": "1.2.3.4"})) is None
    monkeypatch.setattr(main.config, "EDGE_SECRET", "")              # no public chat configured
    assert main.public_client(req(_public())) is None
    assert c  # client built


def test_public_visitors_reach_only_the_chat_paths(monkeypatch):
    c = _client(monkeypatch)
    assert c.get("/api/pulse", headers=_public()).status_code == 404
    assert c.get("/api/backups", headers=_public()).status_code == 404
    assert c.post("/api/theme", json={"color": "rose"}, headers=_public()).status_code == 404
    assert c.get("/api/themes", headers=_public(edge="wrong")).status_code == 200   # not public: normal


def test_public_history_is_empty_and_never_touches_the_database(monkeypatch):
    c = _client(monkeypatch)
    monkeypatch.setattr(main, "pool", NoDatabase())
    r = c.get("/api/history", headers=_public())
    assert r.status_code == 200 and r.json() == {"stored": False, "chats": [], "public": True}


def test_public_chat_is_a_guest_with_short_replies(monkeypatch):
    c = _client(monkeypatch)
    _fake_model(monkeypatch)
    r = c.post("/api/chat", json={"message": "hello"}, headers=_public())
    assert r.status_code == 200
    assert '"stored": false' in r.text and '"token": "Hi"' in r.text and "event: done" in r.text


def test_public_limits_are_stricter(monkeypatch):
    c = _client(monkeypatch)
    _fake_model(monkeypatch)
    n = main.config.PUBLIC_RATE_LIMIT_PER_MIN
    for _ in range(n):
        assert c.post("/api/chat", json={"message": "hi"}, headers=_public()).status_code == 200
    assert c.post("/api/chat", json={"message": "hi"}, headers=_public()).status_code == 429
