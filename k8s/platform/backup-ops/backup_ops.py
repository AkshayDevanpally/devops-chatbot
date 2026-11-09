"""backup-ops: backup status, logs and "Back up now" for the Pulse page.

Runs in the `data` namespace (k8s/platform/65-backup-ops.yaml). chat-api is internet-facing and
has no Kubernetes access; it calls this service instead, and only chat-api may (NetworkPolicy).
This service may only read the backup CronJobs, start Jobs from them and read their logs (RBAC).

    GET  /status            schedules, last/next runs, recent runs
    GET  /logs?job=NAME     last 300 log lines of one backup-related job
    GET  /metrics           backup health for Prometheus (alerts)
    POST /run               {"password": "..."}: backup now, then the off-site copy

Standard library only, so it runs on a plain python image with nothing to build.
"""
import hmac
import json
import os
import re
import signal
import ssl
import threading
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NS = os.getenv("NAMESPACE", "data")
PASSWORD = os.getenv("ADMIN_PASSWORD", "")
API = f"https://{os.getenv('KUBERNETES_SERVICE_HOST', 'kubernetes.default.svc')}:{os.getenv('KUBERNETES_SERVICE_PORT', '443')}"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"

# CronJob name -> what the Pulse page calls it. Only jobs made from these can be listed or read.
KINDS = {"postgres-backup": "backup", "postgres-offsite": "offsite", "postgres-restore-test": "restore-test"}
JOB_NAME = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")

MAX_FAILED_LOGINS = 5            # per 15 minutes, for everyone together
MIN_SECONDS_BETWEEN_RUNS = 120   # a double click doesn't start two backups
_lock = threading.Lock()
_failed: list[float] = []
_last_run = 0.0


def log(event: str, **fields) -> None:
    print(json.dumps({"ts": datetime.now(UTC).isoformat(timespec="seconds"), "event": event, **fields}),
          flush=True)


# ---------------------------------------------------------------- Kubernetes API (urllib only)
def k8s(method: str, path: str, body: dict | None = None, raw: bool = False):
    with open(f"{SA}/token", encoding="utf-8") as f:   # re-read: the token is rotated
        token = f.read().strip()
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        data = r.read()
    return data.decode("utf-8", "replace") if raw else json.loads(data)


def cronjob(name: str) -> dict | None:
    try:
        return k8s("GET", f"/apis/batch/v1/namespaces/{NS}/cronjobs/{name}")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def job_kind(job: dict) -> str | None:
    name = job["spec"]["template"]["metadata"].get("labels", {}).get("app.kubernetes.io/name", "")
    return KINDS.get(name)


def backup_jobs() -> list[dict]:
    items = k8s("GET", f"/apis/batch/v1/namespaces/{NS}/jobs")["items"]
    return [j for j in items if job_kind(j)]


def job_summary(job: dict) -> dict:
    meta, st = job["metadata"], job.get("status", {})
    manual = (meta.get("annotations", {}).get("cronjob.kubernetes.io/instantiate") == "manual"
              or "-manual-" in meta["name"] or meta["name"].startswith(("backup-manual", "restore-test-manual")))
    if st.get("succeeded"):
        state = "succeeded"
    elif any(c["type"] == "Failed" and c["status"] == "True" for c in st.get("conditions", [])):
        state = "failed"
    else:
        state = "running"
    finished = st.get("completionTime") or next(
        (c.get("lastTransitionTime") for c in st.get("conditions", []) if c["type"] == "Failed"), None)
    return {"job": meta["name"], "kind": job_kind(job), "trigger": "manual" if manual else "scheduled",
            "status": state, "started": st.get("startTime") or meta.get("creationTimestamp"), "finished": finished}


# ---------------------------------------------------------------- tiny cron ("next run" on the page)
def _field(spec: str, lo: int, hi: int) -> set[int]:
    out: set[int] = set()
    for part in spec.split(","):
        rng, _, step = part.partition("/")
        a, b = (lo, hi) if rng == "*" else (int(rng.split("-")[0]), int(rng.split("-")[-1]))
        out.update(range(a, b + 1, int(step or 1)))
    return out


def next_run(schedule: str, now: datetime) -> str | None:
    """Next time (UTC) a 5-field cron schedule fires. Day-of-month and day-of-week are ANDed when both
    are restricted, which is enough for the schedules used here."""
    try:
        m, h, dom, mon, dow = schedule.split()
        sets = (_field(m, 0, 59), _field(h, 0, 23), _field(dom, 1, 31), _field(mon, 1, 12),
                {d % 7 for d in _field(dow, 0, 7)})
    except ValueError:
        return None
    t = now.replace(second=0, microsecond=0) + timedelta(minutes=1)
    for _ in range(60 * 24 * 62):
        if (t.minute in sets[0] and t.hour in sets[1] and t.day in sets[2] and t.month in sets[3]
                and (t.weekday() + 1) % 7 in sets[4]):
            return t.isoformat().replace("+00:00", "Z")
        t += timedelta(minutes=1)
    return None


def status() -> dict:
    now = datetime.now(UTC)
    out: dict = {"manual_enabled": bool(PASSWORD)}
    runs = sorted((job_summary(j) for j in backup_jobs()), key=lambda r: r["started"] or "", reverse=True)
    for name, kind in KINDS.items():
        cj = cronjob(name)
        if cj is None:
            out[kind.replace("-", "_")] = {"configured": False}
            continue
        st = cj.get("status", {})
        # The CronJob only records scheduled successes; a manual run ("Back up now") counts too.
        done = [r["finished"] for r in runs if r["kind"] == kind and r["status"] == "succeeded" and r["finished"]]
        last_success = max([t for t in (st.get("lastSuccessfulTime"), *done) if t], default=None)
        finished = [r for r in runs if r["kind"] == kind and r["status"] != "running"]
        out[kind.replace("-", "_")] = {
            "configured": True, "schedule": cj["spec"]["schedule"], "suspended": cj["spec"].get("suspend", False),
            "last_scheduled": st.get("lastScheduleTime"), "last_success": last_success,
            "last_failed": bool(finished) and finished[0]["status"] == "failed",
            "next": None if cj["spec"].get("suspend") else next_run(cj["spec"]["schedule"], now)}
    out["runs"] = runs[:12]
    out["running"] = any(r["status"] == "running" and r["kind"] in ("backup", "offsite") for r in runs)
    return out


def metrics() -> str:
    """Prometheus text format. Timestamps are Unix seconds; 0 = never."""
    def ts(iso: str | None) -> float:
        return datetime.fromisoformat(iso).timestamp() if iso else 0   # Python 3.11+ reads the Z

    st = status()
    lines = ["# HELP backup_configured 1 if the CronJob for this kind exists.", "# TYPE backup_configured gauge",
             "# HELP backup_last_success_timestamp_seconds Last successful run (scheduled or manual).",
             "# TYPE backup_last_success_timestamp_seconds gauge",
             "# HELP backup_last_run_failed 1 if the newest finished run failed.", "# TYPE backup_last_run_failed gauge",
             "# HELP backup_running 1 while a backup or off-site copy runs.", "# TYPE backup_running gauge"]
    for kind in KINDS.values():
        info = st[kind.replace("-", "_")]
        lines.append(f'backup_configured{{kind="{kind}"}} {int(info["configured"])}')
        if info["configured"]:
            lines.append(f'backup_last_success_timestamp_seconds{{kind="{kind}"}} {ts(info["last_success"]):.0f}')
            lines.append(f'backup_last_run_failed{{kind="{kind}"}} {int(info["last_failed"])}')
    lines.append(f"backup_running {int(st['running'])}")
    return "\n".join(lines) + "\n"


def job_log(name: str) -> str:
    if not JOB_NAME.match(name) or name not in {j["metadata"]["name"] for j in backup_jobs()}:
        raise LookupError("not a backup job")
    pods = k8s("GET", f"/api/v1/namespaces/{NS}/pods?labelSelector=job-name%3D{name}")["items"]
    if not pods:
        return "(no pod left for this job: its logs are gone)"
    pod = max(pods, key=lambda p: p["metadata"]["creationTimestamp"])["metadata"]["name"]
    try:
        return k8s("GET", f"/api/v1/namespaces/{NS}/pods/{pod}/log?tailLines=300", raw=True) or "(no output yet)"
    except urllib.error.HTTPError as exc:
        return f"(log not available yet: {exc.code})"


# ---------------------------------------------------------------- "Back up now"
def start_job(cronjob_name: str) -> str:
    cj = cronjob(cronjob_name)
    if cj is None:
        raise LookupError(f"{cronjob_name} not installed")
    body = {
        "apiVersion": "batch/v1", "kind": "Job",
        "metadata": {
            "generateName": f"{cronjob_name}-manual-", "namespace": NS,
            "annotations": {"cronjob.kubernetes.io/instantiate": "manual"},
            "ownerReferences": [{"apiVersion": "batch/v1", "kind": "CronJob", "name": cronjob_name,
                                 "uid": cj["metadata"]["uid"]}],
        },
        "spec": cj["spec"]["jobTemplate"]["spec"],
    }
    return k8s("POST", f"/apis/batch/v1/namespaces/{NS}/jobs", body)["metadata"]["name"]


def wait_for(name: str, timeout: int = 900) -> str:
    end = time.time() + timeout
    while time.time() < end:
        s = job_summary(k8s("GET", f"/apis/batch/v1/namespaces/{NS}/jobs/{name}"))["status"]
        if s != "running":
            return s
        time.sleep(5)
    return "timeout"


def run_chain() -> None:
    """Backup, then (if installed) the off-site copy of that backup."""
    try:
        backup = start_job("postgres-backup")
        log("manual_backup_started", job=backup)
        result = wait_for(backup)
        log("manual_backup_finished", job=backup, result=result)
        if result == "succeeded" and cronjob("postgres-offsite"):
            off = start_job("postgres-offsite")
            log("manual_offsite_started", job=off)
            log("manual_offsite_finished", job=off, result=wait_for(off))
    except Exception as exc:  # noqa: BLE001 — logged; the page shows the job states
        log("manual_run_error", error=str(exc)[:300])


def request_run(password: str) -> tuple[int, dict]:
    global _last_run
    now = time.time()
    with _lock:
        _failed[:] = [t for t in _failed if now - t < 900]
        if not PASSWORD:
            return 503, {"error": "manual backups are off (no admin password set)"}
        if len(_failed) >= MAX_FAILED_LOGINS:
            return 429, {"error": "too many wrong passwords; try again in 15 minutes"}
        if not hmac.compare_digest(password.encode(), PASSWORD.encode()):
            _failed.append(now)
            log("manual_backup_denied")
            return 401, {"error": "wrong password"}
        if now - _last_run < MIN_SECONDS_BETWEEN_RUNS or status()["running"]:
            return 409, {"error": "a backup is already running"}
        _last_run = now
    threading.Thread(target=run_chain, daemon=True).start()
    return 202, {"accepted": True}


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "backup-ops"

    def reply(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        try:
            if self.path == "/healthz":
                return self.reply(200, {"ok": True})
            if self.path == "/status":
                return self.reply(200, status())
            if self.path == "/metrics":
                data = metrics().encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; version=0.0.4")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                return self.wfile.write(data)
            m = re.fullmatch(r"/logs\?job=([a-z0-9-]{1,63})", self.path)
            if m:
                return self.reply(200, {"job": m.group(1), "log": job_log(m.group(1))})
            self.reply(404, {"error": "not found"})
        except LookupError as exc:
            self.reply(404, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            log("error", path=self.path, error=str(exc)[:300])
            self.reply(502, {"error": "Kubernetes API unavailable"})

    def do_POST(self):
        if self.path != "/run":
            return self.reply(404, {"error": "not found"})
        try:
            length = min(int(self.headers.get("Content-Length") or 0), 1024)
            password = str(json.loads(self.rfile.read(length) or b"{}").get("password", ""))[:128]
        except (ValueError, AttributeError):
            return self.reply(400, {"error": "bad request"})
        try:
            code, body = request_run(password)
        except Exception as exc:  # noqa: BLE001
            log("error", path=self.path, error=str(exc)[:300])
            code, body = 502, {"error": "Kubernetes API unavailable"}
        self.reply(code, body)

    def log_message(self, fmt, *args):  # quiet: no per-request access log
        pass


if __name__ == "__main__":
    # PID 1 ignores SIGTERM by default: exit at once instead of waiting out the grace period.
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    log("start", namespace=NS, manual_enabled=bool(PASSWORD))
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
