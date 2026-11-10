"""Public site (Phase 9b): only requests the Pi vouches for (edge secret) count as public. They get the
home rules, except: "Back up now" is refused, colour deploys from the public site are capped per hour,
pipeline logs are trimmed, and the per-visitor limits use the visitor's real address."""
import httpx
from fastapi.testclient import TestClient
from starlette.requests import Request

from app import main

EDGE = "e" * 40


def _client(monkeypatch, secret=EDGE, env="prod"):
    main._hits.clear()
    monkeypatch.setattr(main.config, "EDGE_SECRET", secret)
    monkeypatch.setattr(main.config, "APP_ENV", env)
    return TestClient(main.app)


def _public(ip="203.0.113.7", edge=EDGE):
    return {"X-QwenOps-Edge": edge, "X-QwenOps-Client": ip}


def _req(headers):
    return Request({"type": "http", "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()],
                    "client": ("10.42.0.9", 1), "path": "/", "query_string": b""})


def test_only_the_right_secret_makes_a_request_public(monkeypatch):
    _client(monkeypatch)
    assert main.public_client(_req(_public())) == "203.0.113.7"
    assert main.public_client(_req(_public(edge="wrong"))) is None
    assert main.public_client(_req({"X-QwenOps-Client": "1.2.3.4"})) is None
    assert main.client_key(_req(_public())) == "public:203.0.113.7"
    assert main.client_key(_req({"X-QwenOps-Client": "1.2.3.4"})) == "10.42.0.9"   # header ignored
    monkeypatch.setattr(main.config, "EDGE_SECRET", "")               # public site not set up
    assert main.public_client(_req(_public())) is None


def test_back_up_now_and_unlisted_paths_are_home_only(monkeypatch):
    c = _client(monkeypatch)
    assert c.post("/api/backups/run", json={"password": "x"}, headers=_public()).status_code == 404
    assert c.get("/api/readyz", headers=_public()).status_code == 404
    assert c.get("/api/themes", headers=_public()).status_code == 200          # listed: allowed
    assert c.get("/api/readyz", headers=_public(edge="wrong")).status_code != 404  # not public: normal route


def test_public_colour_deploys_are_capped_per_hour(monkeypatch):
    c = _client(monkeypatch)
    backend = httpx.AsyncClient(base_url="http://pipeline-events",
                                transport=httpx.MockTransport(lambda req: httpx.Response(202, json={"accepted": True})))
    monkeypatch.setattr(main, "pipeline_http", backend)
    cap = main.config.PUBLIC_THEME_PER_HOUR
    for i in range(cap):   # different visitors (fresh cookie each time) so the 1-per-5-min rule doesn't apply
        c.cookies.clear()
        assert c.post("/api/theme", json={"color": "rose"}, headers=_public(ip=f"198.51.100.{i}")).status_code == 202
    c.cookies.clear()
    r = c.post("/api/theme", json={"color": "rose"}, headers=_public(ip="198.51.100.99"))
    assert r.status_code == 429 and "an hour" in r.json()["detail"]
    c.cookies.clear()
    assert c.post("/api/theme", json={"color": "rose"}).status_code == 202      # home visitors aren't capped


def test_public_pipeline_logs_ask_for_the_trimmed_version(monkeypatch):
    c = _client(monkeypatch)
    seen = []

    def handler(req):
        seen.append(dict(req.url.params))
        return httpx.Response(200, json={"log": "ok"})
    monkeypatch.setattr(main, "pipeline_http", httpx.AsyncClient(base_url="http://pipeline-events",
                                                                 transport=httpx.MockTransport(handler)))
    params = {"job": "chatbot", "build": 1, "stage": 8}
    assert c.get("/api/pipeline/log", params=params, headers=_public()).status_code == 200
    assert seen[-1].get("public") == "1"
    assert c.get("/api/pipeline/log", params=params).status_code == 200
    assert "public" not in seen[-1]
