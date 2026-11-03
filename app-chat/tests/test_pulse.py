"""Pulse queries stay inside one environment, odd Prometheus values never break the JSON,
and the rate limiter forgets idle visitors."""
import json

from app import main, pulse


def _all_queries(q: dict) -> list[str]:
    return [
        *q["stats"].values(),
        *(e for group in q["series"].values() for e in group.values()),
        *q["grouped"].values(),
        *q["pods"].values(),
    ]


def test_queries_are_scoped_to_one_env():
    exprs = _all_queries(pulse.build_queries("qa", 15))
    assert all("chatbot-dev" not in e and "chatbot-prod" not in e for e in exprs)
    app_metrics = [e for e in exprs if "http_requests_total" in e or "chat_" in e]
    assert app_metrics and all('namespace="chatbot-qa"' in e for e in app_metrics)


def test_nan_and_inf_become_null():
    result = [{"metric": {}, "values": [[1, "NaN"], [2, "+Inf"], [3, "1.5"]]}]
    points = pulse.first_points(result)
    assert points == [[1.0, None], [2.0, None], [3.0, 1.5]]
    json.dumps(points, allow_nan=False)   # would raise on NaN
    assert pulse.first_value(None) is None


def test_pods_merge_cpu_and_memory():
    cpu = [{"metric": {"namespace": "ai", "pod": "ollama-1"}, "value": [0, "0.25"]}]
    mem = [
        {"metric": {"namespace": "data", "pod": "postgres-0"}, "value": [0, "2048"]},
        {"metric": {"namespace": "ai", "pod": "ollama-1"}, "value": [0, "1024"]},
    ]
    assert pulse.merge_pods({"cpu": cpu, "memory": mem}) == [
        {"namespace": "ai", "pod": "ollama-1", "cpu": 0.25, "memory": 1024.0},
        {"namespace": "data", "pod": "postgres-0", "cpu": None, "memory": 2048.0},
    ]


def test_rate_limiter_forgets_idle_keys(monkeypatch):
    clock = [1000.0]
    monkeypatch.setattr(main, "_now", lambda: clock[0])
    monkeypatch.setattr(main, "_last_sweep", clock[0])
    main._hits.clear()
    for i in range(100):
        main.rate_limited(f"visitor{i}", 5)
    assert len(main._hits) == 100

    clock[0] += main._LONGEST_WINDOW + 1
    main.rate_limited("fresh", 5)
    assert list(main._hits) == ["fresh"]


def test_rate_limiter_still_limits(monkeypatch):
    monkeypatch.setattr(main, "_now", lambda: 5000.0)
    main._hits.clear()
    assert [main.rate_limited("k", 3) for _ in range(4)] == [False, False, False, True]
