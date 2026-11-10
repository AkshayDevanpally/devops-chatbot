"""Chat API: streams replies from a small Qwen model (via Ollama) and stores history
for the first 50 users, keeping each user's newest 15 chats."""
import asyncio
import hmac
import json
import logging
import time
import uuid
from collections import deque
from contextlib import asynccontextmanager

import httpx
import psycopg
from fastapi import FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse
from itsdangerous import BadSignature, URLSafeSerializer
from prometheus_client import Counter, Gauge, Histogram, start_http_server
from psycopg_pool import AsyncConnectionPool
from pydantic import BaseModel, Field, field_validator

from app import capacity, config, pulse

# ---------- logging (JSON to stdout, never message bodies) ----------
logging.basicConfig(level=logging.INFO, format='{"ts":"%(asctime)s","level":"%(levelname)s","msg":%(message)s}')
log = logging.getLogger("chat-api")


def jlog(event: str, **fields):
    log.info(json.dumps({"event": event, "env": config.APP_ENV, **fields}))


# ---------- metrics ----------
CHAT_REQUESTS = Counter("chat_requests_total", "Chat requests", ["outcome"])
# Buckets sized for a small CPU model: full replies can take up to the 120 s timeout.
CHAT_LATENCY = Histogram("chat_reply_seconds", "Time to full reply",
                         buckets=(0.5, 1, 2, 3, 5, 8, 13, 20, 30, 45, 60, 90, 120))
CHAT_FIRST_TOKEN = Histogram("chat_first_token_seconds", "Time to first token",
                             buckets=(0.1, 0.25, 0.5, 1, 2, 3, 5, 8, 13, 20))
CHAT_TOKENS = Counter("chat_tokens", "Tokens streamed from the model")
CHAT_ACTIVE = Gauge("chat_active_streams", "Replies being streamed right now")
CHAT_WAITING = Gauge("chat_waiting", "Chats waiting in line for a model slot")
HTTP_REQUESTS = Counter("http_requests", "HTTP requests", ["route", "method", "status_class"])
HTTP_LATENCY = Histogram("http_request_seconds", "Time until response headers", ["route"])

pool: AsyncConnectionPool | None = None
http: httpx.AsyncClient | None = None
backup_http: httpx.AsyncClient | None = None
pipeline_http: httpx.AsyncClient | None = None
pulse_source: pulse.Pulse | None = None
capacity_source: capacity.Capacity | None = None
signer = URLSafeSerializer(config.SESSION_SECRET, salt="uid")


@asynccontextmanager
async def lifespan(_: FastAPI):
    global pool, http, backup_http, pipeline_http, pulse_source, capacity_source
    pool = AsyncConnectionPool(config.DATABASE_URL, min_size=1, max_size=5, open=False)
    await pool.open(wait=False)
    # Metrics on a separate port that is NOT behind the ingress, so they're never public.
    start_http_server(9100)
    http = httpx.AsyncClient(base_url=config.OLLAMA_URL, timeout=httpx.Timeout(120, connect=5))
    if config.PROMETHEUS_URL:
        pulse_source = pulse.Pulse(config.PROMETHEUS_URL, config.APP_ENV)
        capacity_source = capacity.Capacity(config.PROMETHEUS_URL, config.APP_ENV, config.PROD_BURST_AT)
    if config.BACKUP_OPS_URL:
        backup_http = httpx.AsyncClient(base_url=config.BACKUP_OPS_URL, timeout=httpx.Timeout(10, connect=3))
    if config.PIPELINE_EVENTS_URL:
        pipeline_http = httpx.AsyncClient(base_url=config.PIPELINE_EVENTS_URL, timeout=httpx.Timeout(15, connect=3))
    jlog("startup", model=config.MODEL, pulse=bool(pulse_source), backups=bool(backup_http),
         pipeline=bool(pipeline_http))
    yield
    for source in (pulse_source, capacity_source):
        if source:
            await source.aclose()
    await http.aclose()
    for client in (backup_http, pipeline_http):
        if client:
            await client.aclose()
    await pool.close()


app = FastAPI(title="chat-api", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


# ---------- request metrics (labelled by route, never by raw path, to keep series bounded) ----------
class MetricsMiddleware:
    def __init__(self, inner):
        self.inner = inner

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.inner(scope, receive, send)
        route = scope["path"] if scope["path"] in KNOWN_ROUTES else "other"
        method = scope["method"] if scope["method"] in ("GET", "POST") else "other"
        started = time.monotonic()
        status = 500

        async def send_and_measure(message):
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
                HTTP_LATENCY.labels(route).observe(time.monotonic() - started)
            await send(message)

        try:
            await self.inner(scope, receive, send_and_measure)
        finally:
            HTTP_REQUESTS.labels(route, method, f"{status // 100}xx").inc()


app.add_middleware(MetricsMiddleware)


# ---------- tiny in-memory rate limiter (per user id + IP) ----------
# Counts are per pod: with N API replicas a client can get up to N x the limit.
_hits: dict[str, deque] = {}
_LONGEST_WINDOW = 600.0   # the longest window any caller uses ("Back up now" attempts)
_SWEEP_EVERY = 60.0
_last_sweep = 0.0
_now = time.monotonic


def rate_limited(key: str, limit: int, window: float = 60.0) -> bool:
    global _last_sweep
    now = _now()
    if now - _last_sweep > _SWEEP_EVERY:
        # Forget idle keys, otherwise every visitor's id/IP stays in memory forever.
        _last_sweep = now
        for k in [k for k, q in _hits.items() if not q or now - q[-1] > _LONGEST_WINDOW]:
            del _hits[k]
    q = _hits.setdefault(key, deque())
    while q and now - q[0] > window:
        q.popleft()
    if len(q) >= limit:
        return True
    q.append(now)
    return False


# ---------- public visitors (Phase 9b: Netlify → Tailscale Funnel → Pi → here) ----------
def public_client(request: Request) -> str | None:
    """The visitor's address if the Pi vouches for this request (edge secret), else None.
    Without the secret the X-QwenOps-* headers are ignored, so nobody can fake being public or
    pick their own address to dodge the limits."""
    edge = request.headers.get("x-qwenops-edge", "")
    if config.EDGE_SECRET and edge and hmac.compare_digest(edge.encode(), config.EDGE_SECRET.encode()):
        return request.headers.get("x-qwenops-client", "")[:64] or "unknown"
    return None


PUBLIC_PATHS = {"/api/chat", "/api/history", "/api/status", "/api/wake"}


@app.middleware("http")
async def public_only_chat(request: Request, call_next):
    """The Pi forwards only the chat paths; refuse the rest here too, in case that ever changes."""
    if request.url.path not in PUBLIC_PATHS and public_client(request) is not None:
        return JSONResponse({"detail": "not available on the public site"}, status_code=404)
    return await call_next(request)


def client_key(request: Request) -> str:
    who = public_client(request)
    return f"public:{who}" if who is not None else (request.client.host if request.client else "unknown")


# ---------- identity: signed anonymous cookie ----------
def get_or_set_uid(request: Request, response: Response) -> str:
    raw = request.cookies.get("uid")
    if raw:
        try:
            return signer.loads(raw)
        except BadSignature:
            pass
    uid = uuid.uuid4().hex
    response.set_cookie(
        "uid", signer.dumps(uid), httponly=True, secure=config.COOKIE_SECURE,
        samesite="lax", max_age=60 * 60 * 24 * 90, path="/",
    )
    return uid


async def ensure_user(uid: str) -> bool:
    """Return True if this user's chats are stored (one of the first 50)."""
    async with pool.connection() as conn:
        row = await (await conn.execute("SELECT 1 FROM users WHERE id = %s", (uid,))).fetchone()
        if row:
            return True
        try:
            # Savepoint, so a refused insert doesn't poison the outer transaction.
            async with conn.transaction():
                await conn.execute("INSERT INTO users (id) VALUES (%s)", (uid,))
            return True
        except psycopg.errors.UniqueViolation:
            return True   # same user's two tabs raced; they're stored
        except psycopg.errors.RaiseException as exc:
            if "user_limit_reached" in str(exc):
                return False
            raise


# ---------- models ----------
class ChatIn(BaseModel):
    message: str = Field(min_length=1, max_length=config.MAX_MESSAGE_CHARS)

    @field_validator("message")
    @classmethod
    def clean(cls, v: str) -> str:
        v = "".join(ch for ch in v if ch.isprintable() or ch in "\n\t").strip()
        if not v:
            raise ValueError("empty message")
        return v


class ThemeIn(BaseModel):
    color: str

    @field_validator("color")
    @classmethod
    def allowed(cls, v: str) -> str:
        if v not in config.ALLOWED_THEMES:
            raise ValueError("colour not allowed")
        return v


# ---------- health ----------
@app.get("/api/healthz")
async def healthz():
    return {"ok": True}


@app.get("/api/readyz")
async def readyz():
    try:
        async with pool.connection(timeout=2) as conn:
            await conn.execute("SELECT 1")
        r = await http.get("/", timeout=2)
        r.raise_for_status()
    except Exception:  # noqa: BLE001 — readiness must never crash
        raise HTTPException(503, "not ready")
    return {"ready": True}


# ---------- wake + status (Phase 7 swaps the stub for SQS) ----------
@app.post("/api/wake")
async def wake(request: Request):
    if rate_limited(f"wake:{client_key(request)}", 3):
        raise HTTPException(429, "too many wake requests")
    jlog("wake_requested")
    # Locally the hardware is already on. In Phase 7 this publishes to SQS for the Pi relay.
    return {"accepted": True}


@app.get("/api/status")
async def status():
    """asleep -> waking -> cluster_ready -> model_loading -> ready"""
    try:
        r = await http.get("/api/tags", timeout=3)
        r.raise_for_status()
    except Exception:  # noqa: BLE001
        return {"state": "waking"}
    names = {m.get("name") for m in r.json().get("models", [])}
    if config.MODEL not in names:
        return {"state": "model_loading"}
    return {"state": "ready", "model": config.MODEL}


# ---------- history ----------
@app.get("/api/history")
async def history(request: Request, response: Response):
    uid = get_or_set_uid(request, response)
    if public_client(request) is not None:   # public visitors are always guests: nothing stored
        return {"stored": False, "chats": [], "public": True}
    async with pool.connection() as conn:
        stored = await (await conn.execute("SELECT 1 FROM users WHERE id=%s", (uid,))).fetchone()
        rows = await (await conn.execute(
            "SELECT prompt, reply, created_at FROM chats WHERE user_id=%s ORDER BY created_at, id", (uid,)
        )).fetchall()
    return {
        "stored": bool(stored),
        "chats": [{"prompt": p, "reply": r, "at": c.isoformat()} for p, r, c in rows],
    }


# ---------- overload protection ----------
class ModelGate:
    """A few model slots per pod plus a short line. Full line: refuse at once (fail fast)."""

    def __init__(self, slots: int, queue: int, wait: float):
        self.slots, self.queue, self.wait = slots, queue, wait
        self.active = 0
        self.waiting = 0
        self._free = asyncio.Condition()

    def full(self) -> bool:
        return self.active >= self.slots and self.waiting >= self.queue

    def must_wait(self) -> bool:
        return self.active >= self.slots

    async def acquire(self) -> bool:
        async with self._free:
            if self.active < self.slots:
                self.active += 1
                return True
            if self.waiting >= self.queue:
                return False
            self.waiting += 1
            CHAT_WAITING.inc()
            try:
                await asyncio.wait_for(self._free.wait_for(lambda: self.active < self.slots), self.wait)
                self.active += 1
                return True
            except TimeoutError:
                return False
            finally:
                self.waiting -= 1
                CHAT_WAITING.dec()

    async def release(self) -> None:
        async with self._free:
            self.active -= 1
            self._free.notify()


gate = ModelGate(config.CHAT_SLOTS, config.CHAT_QUEUE, config.CHAT_QUEUE_WAIT_SECONDS)
BUSY = "Busy right now: lots of people are chatting. Try again in a moment."


# ---------- chat (Server-Sent Events) ----------
@app.post("/api/chat")
async def chat(body: ChatIn, request: Request, response: Response):
    uid = get_or_set_uid(request, response)
    public = public_client(request) is not None
    per_visitor = config.PUBLIC_RATE_LIMIT_PER_MIN if public else config.RATE_LIMIT_PER_MIN
    if rate_limited(f"chat:{uid}", per_visitor) or rate_limited(
        f"chatip:{client_key(request)}", per_visitor * (2 if public else 3)
    ) or (public and rate_limited("chat:public-all", config.PUBLIC_CHATS_PER_MIN)):
        CHAT_REQUESTS.labels("rate_limited").inc()
        raise HTTPException(429, "slow down")

    if gate.full():   # the line is full: say so at once, before any work
        CHAT_REQUESTS.labels("busy").inc()
        raise HTTPException(503, BUSY, headers={"Retry-After": "15"})

    # Public visitors never take one of the 50 places with saved history.
    stored = False if public else await ensure_user(uid)
    if public:
        jlog("public_chat")
    messages = [{"role": "system", "content": "You are a concise, friendly assistant."}]
    if stored:
        async with pool.connection() as conn:
            rows = await (await conn.execute(
                "SELECT prompt, reply FROM chats WHERE user_id=%s ORDER BY created_at DESC, id DESC LIMIT %s",
                (uid, config.CONTEXT_EXCHANGES),
            )).fetchall()
        for p, r in reversed(rows):
            messages += [{"role": "user", "content": p}, {"role": "assistant", "content": r}]
    messages.append({"role": "user", "content": body.message})

    async def stream():
        # The slot is taken inside the stream, so it is always given back (finally), even when the
        # browser goes away while waiting in line.
        yield f"event: meta\ndata: {json.dumps({'stored': stored})}\n\n"
        if gate.must_wait() and not gate.full():   # only promise a place in line if there is one
            yield f"event: queued\ndata: {json.dumps({'ahead': gate.waiting + 1})}\n\n"
        if not await gate.acquire():
            CHAT_REQUESTS.labels("busy").inc()
            yield f"event: error\ndata: {json.dumps({'error': BUSY, 'busy': True})}\n\n"
            return
        started = time.monotonic()
        reply_parts: list[str] = []
        CHAT_ACTIVE.inc()
        try:
            try:
                async with http.stream(
                    "POST", "/api/chat",
                    json={"model": config.MODEL, "messages": messages, "stream": True,
                          "options": {"num_predict": config.PUBLIC_MAX_TOKENS if public else 512}},
                ) as r:
                    r.raise_for_status()
                    async for line in r.aiter_lines():
                        if not line:
                            continue
                        chunk = json.loads(line)
                        token = chunk.get("message", {}).get("content", "")
                        if token:
                            if not reply_parts:
                                CHAT_FIRST_TOKEN.observe(time.monotonic() - started)
                            reply_parts.append(token)
                            CHAT_TOKENS.inc()
                            yield f"data: {json.dumps({'token': token})}\n\n"
                        if chunk.get("done"):
                            break
            except Exception as exc:  # noqa: BLE001
                CHAT_REQUESTS.labels("model_error").inc()
                jlog("model_error", error=exc.__class__.__name__)
                yield f"event: error\ndata: {json.dumps({'error': 'model unavailable, try again'})}\n\n"
                return

            reply = "".join(reply_parts)
            if stored and reply:
                async with pool.connection() as conn:
                    await conn.execute(
                        "INSERT INTO chats (user_id, prompt, reply) VALUES (%s, %s, %s)",
                        (uid, body.message, reply),
                    )
            CHAT_LATENCY.observe(time.monotonic() - started)
            CHAT_REQUESTS.labels("ok").inc()
            yield "event: done\ndata: {}\n\n"
        finally:
            CHAT_ACTIVE.dec()   # also runs when the browser disconnects mid-reply
            await gate.release()

    sse = StreamingResponse(stream(), media_type="text/event-stream",
                            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
    # carry the identity cookie set above onto the streaming response
    if "set-cookie" in response.headers:
        sse.headers["set-cookie"] = response.headers["set-cookie"]
    return sse


# ---------- theme (Phase 8 wires this to a Jenkins job) ----------
@app.get("/api/themes")
async def themes():
    return {"themes": config.ALLOWED_THEMES}


async def pipeline_events(method: str, path: str, **kw) -> tuple[int, dict]:
    if not pipeline_http:
        return 503, {"error": "pipeline not connected"}
    try:
        r = await pipeline_http.request(method, path, **kw)
        return r.status_code, r.json()
    except (httpx.HTTPError, ValueError):
        return 502, {"error": "pipeline service unreachable"}


@app.post("/api/theme", status_code=202)
async def request_theme(body: ThemeIn, request: Request, response: Response):
    """"Be a Dev": start the theme-deploy job in Jenkins (through pipeline-events)."""
    uid = get_or_set_uid(request, response)
    if rate_limited(f"theme:{uid}", 1, window=300):
        raise HTTPException(429, "one colour change per 5 minutes")
    # Each environment's page changes that environment's colour; the browser can't pick another one.
    if config.APP_ENV not in ("dev", "qa", "prod"):
        raise HTTPException(503, "colour deploys run only in dev, qa and prod")
    code, data = await pipeline_events("POST", "/theme", json={"color": body.color, "env": config.APP_ENV})
    jlog("theme_requested", color=body.color, env=config.APP_ENV, result=code)
    if code != 202:
        raise HTTPException(code if code in (400, 409, 503) else 502, data.get("error", "not started"))
    return {"accepted": True, "color": body.color, "env": config.APP_ENV}


# ---------- Pipeline page: live Jenkins builds (through pipeline-events) ----------
PIPELINE_JOB = r"^(chatbot|theme-deploy)$"


@app.get("/api/pipeline")
async def pipeline_view(request: Request, response: Response, job: str = Query("chatbot", pattern=PIPELINE_JOB)):
    if rate_limited(f"pipeline:{request.client.host}", 40):
        raise HTTPException(429, "too many refreshes")
    code, data = await pipeline_events("GET", "/pipeline", params={"job": job})
    response.headers["Cache-Control"] = "no-store"
    return data if code == 200 else {"available": False, "job": job, "error": data.get("error", "unavailable")}


@app.get("/api/pipeline/log")
async def pipeline_log(request: Request, response: Response, job: str = Query(pattern=PIPELINE_JOB),
                       build: int = Query(ge=1, le=1_000_000), stage: int = Query(ge=1, le=10_000_000)):
    if rate_limited(f"pipeline-log:{request.client.host}", 40):
        raise HTTPException(429, "too many requests")
    code, data = await pipeline_events("GET", "/log", params={"job": job, "build": build, "stage": stage})
    if code != 200:
        raise HTTPException(404 if code == 404 else 502, data.get("error", "log unavailable"))
    response.headers["Cache-Control"] = "no-store"
    return data


# ---------- Pulse: live dashboard data ----------
async def storage_counts() -> dict | None:
    try:
        async with pool.connection(timeout=2) as conn:
            users, chats = await (await conn.execute(
                "SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM chats)"
            )).fetchone()
    except Exception:  # noqa: BLE001 — the dashboard must still render without the db
        return None
    return {"users": users, "max_users": config.MAX_USERS, "chats": chats,
            "max_chats_per_user": config.MAX_CHATS_PER_USER}


@app.get("/api/pulse")
async def pulse_view(request: Request, response: Response, range_: str = Query("15m", alias="range")):
    if range_ not in pulse.RANGES:
        raise HTTPException(422, "unknown range")
    if rate_limited(f"pulse:{request.client.host}", 30):
        raise HTTPException(429, "too many refreshes")
    if pulse_source:
        data = dict(await pulse_source.snapshot(range_))   # copy: the snapshot is shared and cached
    else:
        data = pulse.unavailable(config.APP_ENV, range_)
    data["model"] = (await status())["state"]
    data["storage"] = await storage_counts()
    response.headers["Cache-Control"] = "no-store"
    return data


# ---------- Capacity: local hardware vs AWS ----------
@app.get("/api/capacity")
async def capacity_view(request: Request, response: Response):
    if rate_limited(f"capacity:{request.client.host}", 30):
        raise HTTPException(429, "too many refreshes")
    data = await capacity_source.snapshot("capacity") if capacity_source else capacity.unavailable()
    response.headers["Cache-Control"] = "no-store"
    return data


# ---------- Backups panel on Pulse (proxied to backup-ops; chat-api has no Kubernetes access) ----------
class BackupRun(BaseModel):
    password: str = Field(min_length=1, max_length=128)


async def backup_ops(method: str, path: str, **kw) -> tuple[int, dict]:
    if not backup_http:
        return 503, {"error": "backups not connected"}
    try:
        r = await backup_http.request(method, path, **kw)
        return r.status_code, r.json()
    except (httpx.HTTPError, ValueError):
        return 502, {"error": "backup service unreachable"}


@app.get("/api/backups")
async def backups_view(request: Request, response: Response):
    if rate_limited(f"backups:{request.client.host}", 30):
        raise HTTPException(429, "too many refreshes")
    code, data = await backup_ops("GET", "/status")
    response.headers["Cache-Control"] = "no-store"
    return data if code == 200 else {"available": False, "error": data.get("error", "unavailable")}


@app.get("/api/backups/log")
async def backup_log(request: Request, response: Response, job: str = Query(pattern=r"^[a-z0-9-]{1,63}$")):
    if rate_limited(f"backup-log:{request.client.host}", 30):
        raise HTTPException(429, "too many requests")
    code, data = await backup_ops("GET", "/logs", params={"job": job})
    if code != 200:
        raise HTTPException(404 if code == 404 else 502, data.get("error", "log unavailable"))
    response.headers["Cache-Control"] = "no-store"
    return data


@app.post("/api/backups/run", status_code=202)
async def backup_run(body: BackupRun, request: Request):
    # backup-ops checks the password and limits wrong guesses for everyone; this limits per IP too.
    if rate_limited(f"backup-run:{request.client.host}", 5, window=600):
        raise HTTPException(429, "too many attempts, try again in a few minutes")
    code, data = await backup_ops("POST", "/run", json={"password": body.password})
    jlog("backup_run_requested", result=code)
    if code != 202:
        raise HTTPException(code if code in (401, 409, 429, 503) else 502, data.get("error", "backup not started"))
    return data


# Read by MetricsMiddleware; anything else is counted as route="other".
KNOWN_ROUTES = frozenset(r.path for r in app.routes)
