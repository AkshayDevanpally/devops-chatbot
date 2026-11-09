"""pipeline-events: live Jenkins builds for the Pipeline page, and "Be a Dev" colour deploys.

Runs in the ci namespace (k8s/ci/30-pipeline-events.yaml). chat-api is internet-facing and has no Jenkins
access; it calls this service, which only chat-api may reach. This service talks to Jenkins as the
pipeline-viewer account, which may read builds and start jobs, and can't approve prod.

    GET  /pipeline?job=chatbot|theme-deploy        latest runs with their stages
    GET  /log?job=...&build=N&stage=ID              one stage's log (secrets redacted, last 400 lines)
    POST /theme {"color": "rose"}                   start theme-deploy (409 if one is running)

Standard library only.
"""
import base64
import html
import http.cookiejar
import json
import os
import re
import signal
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

JENKINS = os.getenv("JENKINS_URL", "http://jenkins.ci.svc.cluster.local:8080").rstrip("/")
USER = os.getenv("JENKINS_USER", "pipeline-viewer")
PASSWORD = os.getenv("JENKINS_PASSWORD", "")
JOBS = ("chatbot", "theme-deploy")
COLORS = ("teal", "indigo", "rose", "amber", "emerald", "slate")
AUTH = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
_cache: dict[str, tuple[float, dict]] = {}
_lock = threading.Lock()

# Logs can show up on a public page: hide anything that looks like a secret (same idea as the Journal).
REDACT = [
    (re.compile(r"-----BEGIN [A-Z ]+-----.*?-----END [A-Z ]+-----", re.DOTALL), "‹key›"),
    (re.compile(r"\bssh-(?:ed25519|rsa|dss)\s+AAAA[0-9A-Za-z+/=]+"), "‹ssh-key›"),
    (re.compile(r"(?i)\b(password|passwd|secret|token|apikey|api_key)(\s*[:=]\s*)\S+"), r"\1\2‹redacted›"),
    (re.compile(r"(?i)(authorization:\s*)(bearer|basic)\s+\S+"), r"\1\2 ‹redacted›"),
    (re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), "‹aws-key›"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"), "‹github-token›"),
    (re.compile(r"\b[0-9a-f]{40,}\b"), "‹hex›"),
]


def redact(text: str) -> str:
    for pattern, repl in REDACT:
        text = pattern.sub(repl, text)
    return text


def log(event: str, **fields) -> None:
    print(json.dumps({"ts": datetime.now(UTC).isoformat(timespec="seconds"), "event": event, **fields}), flush=True)


# ---------------------------------------------------------------- Jenkins REST
def get(path: str):
    req = urllib.request.Request(JENKINS + path, headers={"Authorization": AUTH})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def post_with_crumb(path: str) -> int:
    """Jenkins wants a CSRF crumb for POSTs made with a password, tied to the same session (cookie)."""
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    req = urllib.request.Request(JENKINS + "/crumbIssuer/api/json", headers={"Authorization": AUTH})
    with opener.open(req, timeout=10) as r:
        crumb = json.loads(r.read())
    req = urllib.request.Request(JENKINS + path, data=b"", method="POST",
                                 headers={"Authorization": AUTH, crumb["crumbRequestField"]: crumb["crumb"]})
    with opener.open(req, timeout=10) as r:
        return r.status


def ms_to_iso(ms) -> str | None:
    return datetime.fromtimestamp(ms / 1000, UTC).isoformat().replace("+00:00", "Z") if ms else None


def run_details(job: str, number: str) -> dict:
    """Commit, colour parameter, and the approval question if the run waits for one."""
    out: dict = {}
    try:
        d = get(f"/job/{job}/{number}/api/json?tree=actions[parameters[name,value],lastBuiltRevision[SHA1]]")
        for a in d.get("actions", []):
            for p in a.get("parameters", []) or []:
                if p.get("name") == "COLOR":
                    out["color"] = p.get("value")
            sha = (a.get("lastBuiltRevision") or {}).get("SHA1")
            if sha:
                out["commit"] = sha[:7]
    except (urllib.error.URLError, ValueError):
        pass
    return out


def pipeline(job: str) -> dict:
    with _lock:
        hit = _cache.get(job)
        if hit and time.monotonic() - hit[0] < 2:
            return hit[1]
    runs = []
    for r in get(f"/job/{job}/wfapi/runs")[:5]:
        run = {"number": int(r["id"]), "status": r.get("status"), "started": ms_to_iso(r.get("startTimeMillis")),
               "duration_ms": r.get("durationMillis"),
               "stages": [{"id": s["id"], "name": s["name"], "status": s.get("status"),
                           "started": ms_to_iso(s.get("startTimeMillis")), "duration_ms": s.get("durationMillis")}
                          for s in r.get("stages", [])]}
        run.update(run_details(job, r["id"]))
        if r.get("status") == "PAUSED_PENDING_INPUT":
            try:
                pending = get(f"/job/{job}/{r['id']}/wfapi/pendingInputActions")
                run["waiting_for"] = pending[0].get("message") if pending else "approval"
            except (urllib.error.URLError, ValueError):
                run["waiting_for"] = "approval"
        runs.append(run)
    data = {"available": True, "job": job, "runs": runs}
    with _lock:
        _cache[job] = (time.monotonic(), data)
    return data


def stage_log(job: str, build: int, stage: str) -> dict:
    d = get(f"/job/{job}/{build}/execution/node/{stage}/wfapi/describe")
    lines = []
    for node in d.get("stageFlowNodes", []):
        desc = node.get("parameterDescription")
        lines.append(f"$ {node.get('name', 'step')}" + (f": {desc}" if desc else ""))
        try:
            text = get(f"/job/{job}/{build}/execution/node/{node['id']}/wfapi/log").get("text", "")
        except (urllib.error.URLError, ValueError):
            text = ""
        text = html.unescape(re.sub(r"<[^>]+>", "", text or ""))
        lines.extend(text.rstrip("\n").splitlines())
    text = redact("\n".join(lines[-400:]))
    return {"job": job, "build": build, "stage": stage, "status": d.get("status"), "log": text or "(no output yet)"}


def start_theme(color: str) -> tuple[int, dict]:
    if color not in COLORS:
        return 400, {"error": "unknown colour"}
    d = get("/job/theme-deploy/api/json?tree=inQueue,lastBuild[number,building]")
    if d.get("inQueue") or (d.get("lastBuild") or {}).get("building"):
        return 409, {"error": "a colour change is already on its way; watch it on the Pipeline page"}
    status = post_with_crumb("/job/theme-deploy/buildWithParameters?" + urllib.parse.urlencode({"COLOR": color}))
    log("theme_requested", color=color, jenkins_status=status)
    _cache.pop("theme-deploy", None)
    return 202, {"accepted": True, "color": color}


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "pipeline-events"

    def reply(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        try:
            if url.path == "/healthz":
                return self.reply(200, {"ok": bool(PASSWORD)})
            if url.path == "/pipeline":
                job = q.get("job", "chatbot")
                if job not in JOBS:
                    return self.reply(400, {"error": "unknown job"})
                return self.reply(200, pipeline(job))
            if url.path == "/log":
                job, build, stage = q.get("job", ""), q.get("build", ""), q.get("stage", "")
                if job not in JOBS or not build.isdigit() or not stage.isdigit():
                    return self.reply(400, {"error": "need job, build and stage"})
                return self.reply(200, stage_log(job, int(build), stage))
            self.reply(404, {"error": "not found"})
        except urllib.error.HTTPError as exc:
            self.reply(404 if exc.code == 404 else 502, {"error": f"Jenkins answered {exc.code}"})
        except (urllib.error.URLError, OSError, ValueError) as exc:
            log("jenkins_unreachable", error=str(exc)[:200])
            self.reply(502, {"error": "Jenkins unreachable"})

    def do_POST(self):
        if self.path != "/theme":
            return self.reply(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 1024)) or b"{}")
            code, data = start_theme(str(body.get("color", "")))
        except ValueError:
            code, data = 400, {"error": "bad request"}
        except (urllib.error.URLError, OSError) as exc:
            log("jenkins_unreachable", error=str(exc)[:200])
            code, data = 502, {"error": "Jenkins unreachable"}
        self.reply(code, data)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    log("start", jenkins=JENKINS, user=USER, password_set=bool(PASSWORD))
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
