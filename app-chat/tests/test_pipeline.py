"""Pipeline page and "Be a Dev": chat-api only proxies to pipeline-events (no Jenkins access), validates
input before any call, and fails softly when the pipeline isn't connected."""
import httpx
from fastapi.testclient import TestClient

from app import main


def _client(monkeypatch, handler=None):
    main._hits.clear()
    backend = None
    if handler:
        backend = httpx.AsyncClient(base_url="http://pipeline-events", transport=httpx.MockTransport(handler))
    monkeypatch.setattr(main, "pipeline_http", backend)
    return TestClient(main.app)


def test_not_connected_means_demo_and_colour_refused(monkeypatch):
    c = _client(monkeypatch)
    assert c.get("/api/pipeline").json()["available"] is False
    assert c.post("/api/theme", json={"color": "rose"}).status_code == 503


def test_runs_logs_and_colour_are_passed_through(monkeypatch):
    seen = []

    def handler(req: httpx.Request):
        seen.append((req.method, req.url.path, str(req.url.query, "ascii") if isinstance(req.url.query, bytes) else req.url.query, req.content))
        if req.url.path == "/pipeline":
            return httpx.Response(200, json={"available": True, "job": "theme-deploy", "runs": []})
        if req.url.path == "/log":
            return httpx.Response(200, json={"log": "ok"})
        return httpx.Response(202, json={"accepted": True})

    c = _client(monkeypatch, handler)
    assert c.get("/api/pipeline", params={"job": "theme-deploy"}).json()["job"] == "theme-deploy"
    assert c.get("/api/pipeline/log", params={"job": "chatbot", "build": 3, "stage": 7}).json() == {"log": "ok"}
    assert c.post("/api/theme", json={"color": "rose"}).status_code == 202
    assert seen[-1][0] == "POST" and seen[-1][1] == "/theme" and b'"rose"' in seen[-1][3]


def test_bad_input_never_reaches_the_service(monkeypatch):
    calls = []
    c = _client(monkeypatch, lambda req: calls.append(req) or httpx.Response(200, json={}))
    assert c.get("/api/pipeline", params={"job": "other-job"}).status_code == 422
    assert c.get("/api/pipeline/log", params={"job": "chatbot", "build": "1;rm", "stage": 7}).status_code == 422
    assert c.post("/api/theme", json={"color": "purple"}).status_code == 422
    assert calls == []


def test_busy_colour_job_is_refused(monkeypatch):
    c = _client(monkeypatch, lambda req: httpx.Response(409, json={"error": "a colour change is already on its way"}))
    r = c.post("/api/theme", json={"color": "amber"})
    assert r.status_code == 409 and "already" in r.json()["detail"]


def test_one_colour_change_per_five_minutes_per_visitor(monkeypatch):
    c = _client(monkeypatch, lambda req: httpx.Response(202, json={"accepted": True}))
    assert c.post("/api/theme", json={"color": "amber"}).status_code == 202   # sets the visitor cookie
    assert c.post("/api/theme", json={"color": "rose"}).status_code == 429
