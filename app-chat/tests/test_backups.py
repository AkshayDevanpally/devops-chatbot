"""Backups panel: chat-api only proxies to backup-ops, never needs Kubernetes access, and fails
softly when backup-ops is absent or down."""
import httpx
from fastapi.testclient import TestClient

from app import main


def _client(monkeypatch, handler=None):
    main._hits.clear()
    backend = None
    if handler:
        backend = httpx.AsyncClient(base_url="http://backup-ops", transport=httpx.MockTransport(handler))
    monkeypatch.setattr(main, "backup_http", backend)
    return TestClient(main.app)   # not a context manager: no lifespan, so no database needed


def test_not_connected_means_unavailable_not_an_error(monkeypatch):
    c = _client(monkeypatch)
    r = c.get("/api/backups")
    assert r.status_code == 200 and r.json()["available"] is False
    assert c.post("/api/backups/run", json={"password": "x"}).status_code == 503


def test_status_and_password_are_passed_through(monkeypatch):
    seen = []

    def handler(req: httpx.Request):
        seen.append((req.method, req.url.path, req.content))
        if req.url.path == "/status":
            return httpx.Response(200, json={"running": False, "runs": []})
        if req.url.path == "/run":
            return httpx.Response(401, json={"error": "wrong password"})
        return httpx.Response(404, json={"error": "not a backup job"})

    c = _client(monkeypatch, handler)
    assert c.get("/api/backups").json() == {"running": False, "runs": []}
    r = c.post("/api/backups/run", json={"password": "guess"})
    assert r.status_code == 401 and r.json()["detail"] == "wrong password"
    assert seen[-1][0] == "POST" and b'"guess"' in seen[-1][2]
    assert c.get("/api/backups/log", params={"job": "postgres-0"}).status_code == 404


def test_log_job_name_is_validated_before_any_call(monkeypatch):
    calls = []
    c = _client(monkeypatch, lambda req: calls.append(req) or httpx.Response(200, json={}))
    assert c.get("/api/backups/log", params={"job": "../../secrets"}).status_code == 422
    assert c.post("/api/backups/run", json={"password": ""}).status_code == 422
    assert calls == []


def test_wrong_guesses_are_limited_per_ip(monkeypatch):
    c = _client(monkeypatch, lambda req: httpx.Response(401, json={"error": "wrong password"}))
    codes = [c.post("/api/backups/run", json={"password": "x"}).status_code for _ in range(6)]
    assert codes == [401] * 5 + [429]
