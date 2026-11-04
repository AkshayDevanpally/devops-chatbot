"""Capacity queries keep local and AWS numbers apart, and odd Prometheus values stay valid JSON."""
import asyncio
import json

from app import capacity


def test_local_queries_exclude_aws_and_aws_queries_only_aws():
    q = capacity.build_queries(3)
    local = [*q["local"].values(), *q["local_series"].values(), *q["namespaces"].values()]
    machine = [e for e in local if "machine_" in e or "node_" in e or "container_" in e]
    assert machine and all('cloud!="aws"' in e for e in machine)
    aws = [*q["aws"].values(), *q["aws_series"].values()]
    assert aws and all('cloud="aws"' in e for e in aws)


def test_namespace_rows_sorted_by_memory_and_nan_safe():
    memory = [{"metric": {"namespace": "ai"}, "value": [0, "1000"]},
              {"metric": {"namespace": "data"}, "value": [0, "NaN"]},
              {"metric": {"namespace": "ci"}, "value": [0, "3000"]}]
    cpu = [{"metric": {"namespace": "ai"}, "value": [0, "0.5"]}]
    rows = capacity.namespace_rows(memory, cpu)
    assert [r["namespace"] for r in rows] == ["ci", "ai", "data"]
    assert rows[2]["memory_bytes"] is None and rows[1]["cpu_cores"] == 0.5
    json.dumps(rows, allow_nan=False)


def test_nothing_in_aws_means_not_running():
    class Fake(capacity.Capacity):
        async def _get(self, path, params):
            expr = params["query"]
            if 'cloud="aws"' in expr:
                return []                       # Prometheus answers, but no AWS series exist
            if "query_range" in path:
                return [{"metric": {}, "values": [[1, "0.25"]]}]
            if "by (namespace)" in expr:
                return [{"metric": {"namespace": "ai"}, "value": [0, "5"]}]
            return [{"metric": {}, "value": [0, "0.4"]}]

    async def run():
        src = Fake("http://prometheus:9090", "dev", 3)
        try:
            return await src.snapshot("capacity")
        finally:
            await src.aclose()

    data = asyncio.run(run())
    assert data["available"] is True
    assert data["local"]["cpu_ratio"] == 0.4 and data["local"]["prod_burst_at"] == 3
    assert data["aws"]["burst"] == {"running": False, "nodes": 0, "cpu_ratio": None,
                                    "memory_ratio": None, "series": []}
    assert data["aws"]["rds"]["running"] is False
    json.dumps(data, allow_nan=False)
