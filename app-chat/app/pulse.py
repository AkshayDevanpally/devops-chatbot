"""Pulse: data for the live dashboard page.

The browser never talks to Prometheus and can't send PromQL. It only picks one of
RANGES; every query below is fixed and scoped to this environment's namespace plus
the shared ones (model, database, monitoring)."""
import asyncio
import math
import time

import httpx

RANGES = {"15m": (900, 15), "1h": (3600, 30), "6h": (21600, 120)}  # span seconds, step seconds
CACHE_SECONDS = 4.0
# Health probes and this page's own refreshes would drown out real traffic on a small app.
_REAL_TRAFFIC = 'route!~"/api/(healthz|readyz|pulse|capacity)"'


def workloads(env: str) -> list[tuple[str, str]]:
    """(namespace, label) in a fixed order, so each workload keeps its chart colour."""
    return [
        (f"chatbot-{env}", f"Chat app ({env})"),
        ("ai", "Model (Ollama)"),
        ("data", "Database"),
        ("monitoring", "Monitoring"),
    ]


def build_queries(env: str, step: int) -> dict:
    ns = f'namespace="chatbot-{env}"'
    traffic = f"{ns},{_REAL_TRAFFIC}"
    containers = 'namespace=~"{}",container!=""'.format("|".join(n for n, _ in workloads(env)))
    w = f"{max(60, step * 2)}s"  # rate window: at least 4 scrapes, wider for coarse steps

    def quantile(q: float, metric: str, window: str) -> str:
        return f"histogram_quantile({q}, sum by (le) (rate({metric}_bucket{{{ns}}}[{window}])))"

    return {
        "stats": {
            "requests_per_sec": f"sum(rate(http_requests_total{{{traffic}}}[1m]))",
            "error_ratio": (f'sum(rate(http_requests_total{{{traffic},status_class="5xx"}}[5m]))'
                            f" / sum(rate(http_requests_total{{{traffic}}}[5m]))"),
            "chat_p95_seconds": quantile(0.95, "chat_reply_seconds", "5m"),
            "first_token_p50_seconds": quantile(0.5, "chat_first_token_seconds", "5m"),
            "tokens_per_sec": f"sum(rate(chat_tokens_total{{{ns}}}[1m]))",
            "active_chats": f"sum(chat_active_streams{{{ns}}})",
            "api_pods_up": f'count(up{{job="chat-api",{ns}}} == 1)',
            "host_cpu_ratio": "sum(rate(node_cpu_usage_seconds_total[1m])) / sum(machine_cpu_cores)",
            "host_memory_ratio": "sum(node_memory_working_set_bytes) / sum(machine_memory_bytes)",
        },
        # one line per entry
        "series": {
            "requests": {"Requests/s": f"sum(rate(http_requests_total{{{traffic}}}[{w}]))"},
            "latency": {
                "p50": quantile(0.5, "chat_reply_seconds", w),
                "p95": quantile(0.95, "chat_reply_seconds", w),
            },
            "tokens": {"Tokens/s": f"sum(rate(chat_tokens_total{{{ns}}}[{w}]))"},
        },
        # one line per workload namespace
        "grouped": {
            "cpu": f"sum by (namespace) (rate(container_cpu_usage_seconds_total{{{containers}}}[{w}]))",
            "memory": f"sum by (namespace) (container_memory_working_set_bytes{{{containers}}})",
        },
        # one table row per pod
        "pods": {
            "cpu": f"sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{containers}}}[1m]))",
            "memory": f"sum by (namespace, pod) (container_memory_working_set_bytes{{{containers}}})",
        },
    }


# ---------- parsing (NaN/Inf become null so the JSON stays valid) ----------
def num(raw) -> float | None:
    try:
        v = float(raw)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) else None


def first_value(result: list | None) -> float | None:
    return num(result[0]["value"][1]) if result else None


def to_points(values: list) -> list:
    return [[float(t), num(v)] for t, v in values]


def first_points(result: list | None) -> list:
    return to_points(result[0]["values"]) if result else []


def points_by(result: list | None, label: str) -> dict[str, list]:
    return {s["metric"].get(label, ""): to_points(s["values"]) for s in result or []}


def merge_pods(parts: dict[str, list | None]) -> list[dict]:
    rows: dict[tuple, dict] = {}
    for field, result in parts.items():
        for s in result or []:
            key = (s["metric"].get("namespace", ""), s["metric"].get("pod", ""))
            row = rows.setdefault(key, {"namespace": key[0], "pod": key[1], "cpu": None, "memory": None})
            row[field] = num(s["value"][1])
    return sorted(rows.values(), key=lambda r: (r["namespace"], r["pod"]))


def unavailable(env: str, rng: str) -> dict:
    return {"available": False, "env": env, "range": rng, "stats": {}, "charts": {}, "pods": []}


# ---------- fetching ----------
class Pulse:
    def __init__(self, base_url: str, env: str):
        self.env = env
        self._http = httpx.AsyncClient(base_url=base_url, timeout=httpx.Timeout(3, connect=2))
        self._cache: dict[str, tuple[float, dict]] = {}
        self._lock = asyncio.Lock()

    async def aclose(self):
        await self._http.aclose()

    def _cached(self, rng: str) -> dict | None:
        hit = self._cache.get(rng)
        return hit[1] if hit and time.monotonic() - hit[0] < CACHE_SECONDS else None

    async def snapshot(self, rng: str) -> dict:
        """Cached for a few seconds so many open tabs cost Prometheus one set of queries."""
        if (data := self._cached(rng)) is not None:
            return data
        async with self._lock:
            if (data := self._cached(rng)) is not None:
                return data
            data = await self._collect(rng)
            self._cache[rng] = (time.monotonic(), data)
            return data

    async def _get(self, path: str, params: dict) -> list | None:
        try:
            r = await self._http.get(path, params=params)
            r.raise_for_status()
            body = r.json()
            return body["data"]["result"] if body.get("status") == "success" else None
        except (httpx.HTTPError, ValueError, KeyError):
            return None

    async def _collect(self, rng: str) -> dict:
        span, step = RANGES[rng]
        q = build_queries(self.env, step)
        end = math.floor(time.time() / step) * step  # step-aligned, so every line shares timestamps
        start = end - span

        def instant(expr):
            return self._get("/api/v1/query", {"query": expr})

        def ranged(expr):
            return self._get("/api/v1/query_range", {"query": expr, "start": start, "end": end, "step": step})

        lines = [(chart, name, expr) for chart, group in q["series"].items() for name, expr in group.items()]
        results = await asyncio.gather(
            *(instant(e) for e in q["stats"].values()),
            *(ranged(e) for _, _, e in lines),
            *(ranged(e) for e in q["grouped"].values()),
            *(instant(e) for e in q["pods"].values()),
        )
        it = iter(results)
        stats = {k: first_value(next(it)) for k in q["stats"]}
        charts: dict[str, list] = {}
        for chart, name, _ in lines:
            charts.setdefault(chart, []).append({"name": name, "points": first_points(next(it))})
        for chart in q["grouped"]:
            by_ns = points_by(next(it), "namespace")
            charts[chart] = [{"name": label, "points": by_ns.get(ns, [])} for ns, label in workloads(self.env)]
        pods = merge_pods({field: next(it) for field in q["pods"]})

        return {
            "available": any(r is not None for r in results),
            "env": self.env, "range": rng, "start": start, "end": end, "step": step,
            "stats": stats, "charts": charts, "pods": pods,
        }
