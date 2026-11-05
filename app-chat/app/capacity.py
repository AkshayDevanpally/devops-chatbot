"""Capacity: data for the Capacity page (local hardware vs AWS).

Same safety model as Pulse: the browser sends no parameters and no PromQL; every query
below is fixed. The page shows the whole host, so queries cover every namespace.

Local vs AWS is decided by one label: anything scraped from AWS carries cloud="aws"
(added by the scrape config when AWS burst compute comes in, Phase 6). Local queries exclude
it, so burst nodes never inflate the home server's numbers. With nothing running in AWS,
the AWS half reports "not running", which is the normal, zero-cost state. The database is
never in AWS: it stays on the home server and shows up in the local half (namespace "data").
"""
import asyncio
import math
import time

from app.pulse import Pulse, first_points, first_value, num

SPAN, STEP = 3600, 30            # history: last hour, one point per 30 s
LOCAL = 'cloud!="aws"'
AWS = 'cloud="aws"'


def build_queries(prod_burst_at: int) -> dict:
    containers = f'container!="",{LOCAL}'
    return {
        "local": {
            "cpu_ratio": f"sum(rate(node_cpu_usage_seconds_total{{{LOCAL}}}[1m])) / sum(machine_cpu_cores{{{LOCAL}}})",
            "memory_ratio": f"sum(node_memory_working_set_bytes{{{LOCAL}}}) / sum(machine_memory_bytes{{{LOCAL}}})",
            "memory_used_bytes": f"sum(node_memory_working_set_bytes{{{LOCAL}}})",
            "memory_total_bytes": f"sum(machine_memory_bytes{{{LOCAL}}})",
            "cpu_cores": f"sum(machine_cpu_cores{{{LOCAL}}})",
            "swap_bytes": f"sum(node_swap_usage_bytes{{{LOCAL}}})",
            "pods": f"count(count by (namespace, pod) (container_memory_working_set_bytes{{{containers}}}))",
            # Prod's API pods vs the local ceiling: at the ceiling, extra load bursts to AWS (Phase 6).
            "prod_api_pods": 'count(up{job="chat-api",namespace="chatbot-prod"} == 1)',
        },
        "local_series": {
            "cpu": f"sum(rate(node_cpu_usage_seconds_total{{{LOCAL}}}[2m])) / sum(machine_cpu_cores{{{LOCAL}}})",
            "memory": f"sum(node_memory_working_set_bytes{{{LOCAL}}}) / sum(machine_memory_bytes{{{LOCAL}}})",
        },
        "namespaces": {
            "memory": f"sum by (namespace) (container_memory_working_set_bytes{{{containers}}})",
            "cpu": f"sum by (namespace) (rate(container_cpu_usage_seconds_total{{{containers}}}[2m]))",
        },
        "aws": {
            # Burst compute (Phase 6): nodes in AWS, scraped with cloud="aws".
            "burst_nodes": f"count(machine_cpu_cores{{{AWS}}})",
            "burst_cpu_ratio": f"sum(rate(node_cpu_usage_seconds_total{{{AWS}}}[1m])) / sum(machine_cpu_cores{{{AWS}}})",
            "burst_memory_ratio": f"sum(node_memory_working_set_bytes{{{AWS}}}) / sum(machine_memory_bytes{{{AWS}}})",
        },
        "aws_series": {
            "burst_cpu": f"sum(rate(node_cpu_usage_seconds_total{{{AWS}}}[2m])) / sum(machine_cpu_cores{{{AWS}}})",
        },
        "prod_burst_at": prod_burst_at,
    }


def by_namespace(result: list | None) -> dict[str, float | None]:
    return {s["metric"].get("namespace", ""): num(s["value"][1]) for s in result or []}


def namespace_rows(memory: list | None, cpu: list | None) -> list[dict]:
    mem, cores = by_namespace(memory), by_namespace(cpu)
    rows = [{"namespace": ns, "memory_bytes": mem.get(ns), "cpu_cores": cores.get(ns)}
            for ns in sorted(set(mem) | set(cores))]
    return sorted(rows, key=lambda r: r["memory_bytes"] or 0, reverse=True)


def unavailable() -> dict:
    return {"available": False, "local": {}, "aws": {"burst": {"running": False}}}


class Capacity(Pulse):
    """Reuses Pulse's Prometheus client, cache and lock; only the queries differ."""

    def __init__(self, base_url: str, env: str, prod_burst_at: int):
        super().__init__(base_url, env)
        self.prod_burst_at = prod_burst_at

    async def _collect(self, _key: str) -> dict:
        q = build_queries(self.prod_burst_at)
        end = math.floor(time.time() / STEP) * STEP
        start = end - SPAN

        def instant(expr):
            return self._get("/api/v1/query", {"query": expr})

        def ranged(expr):
            return self._get("/api/v1/query_range", {"query": expr, "start": start, "end": end, "step": STEP})

        groups = [("local", instant), ("local_series", ranged), ("namespaces", instant),
                  ("aws", instant), ("aws_series", ranged)]
        jobs = [(g, k, fn(expr)) for g, fn in groups for k, expr in q[g].items()]
        results = await asyncio.gather(*(job for _, _, job in jobs))
        raw = {(g, k): r for (g, k, _), r in zip(jobs, results)}

        local = {k: first_value(raw[("local", k)]) for k in q["local"]}
        local["prod_burst_at"] = self.prod_burst_at
        aws = {k: first_value(raw[("aws", k)]) for k in q["aws"]}
        burst_running = bool(aws["burst_nodes"])

        return {
            "available": any(r is not None for r in results),
            "start": start, "end": end, "step": STEP,
            "local": {
                **local,
                "series": {k: first_points(raw[("local_series", k)]) for k in q["local_series"]},
                "namespaces": namespace_rows(raw[("namespaces", "memory")], raw[("namespaces", "cpu")]),
            },
            "aws": {
                "burst": {
                    "running": burst_running,
                    "nodes": aws["burst_nodes"] or 0,
                    "cpu_ratio": aws["burst_cpu_ratio"],
                    "memory_ratio": aws["burst_memory_ratio"],
                    "series": first_points(raw[("aws_series", "burst_cpu")]) if burst_running else [],
                },
            },
        }
