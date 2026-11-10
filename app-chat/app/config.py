"""All configuration comes from environment variables (12-factor)."""
import os


def _read_secret(name: str, default: str = "") -> str:
    """Read NAME from env, or from the file named in NAME_FILE (mounted secret)."""
    file_path = os.getenv(f"{name}_FILE")
    if file_path and os.path.exists(file_path):
        with open(file_path, encoding="utf-8") as f:
            return f.read().strip()
    return os.getenv(name, default)


DATABASE_URL = _read_secret("DATABASE_URL")
SESSION_SECRET = _read_secret("SESSION_SECRET")
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama:11434")
MODEL = os.getenv("MODEL", "qwen2.5:0.5b")
APP_ENV = os.getenv("APP_ENV", "local")
# Private Prometheus for the Pulse page. Empty = Pulse shows "not connected".
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "")
# Prod's local ceiling of API pods (helm values-prod: api.hpa.maxReplicas). At this many,
# extra load is meant to burst to AWS; the Capacity page shows how close prod is.
PROD_BURST_AT = int(os.getenv("PROD_BURST_AT", "3"))
# backup-ops in the data namespace: backup status, logs and "Back up now" on the Pulse page.
# Empty = the Backups panel says "not connected" (e.g. Docker Compose).
BACKUP_OPS_URL = os.getenv("BACKUP_OPS_URL", "")
# pipeline-events in the ci namespace: live Jenkins builds (Pipeline page) and "Be a Dev" colour deploys.
# Empty = the Pipeline page runs its demo, and colour requests are refused.
PIPELINE_EVENTS_URL = os.getenv("PIPELINE_EVENTS_URL", "")

MAX_USERS = 50            # enforced in the database too
MAX_CHATS_PER_USER = 15   # enforced in the database too
MAX_MESSAGE_CHARS = int(os.getenv("MAX_MESSAGE_CHARS", "2000"))
CONTEXT_EXCHANGES = int(os.getenv("CONTEXT_EXCHANGES", "4"))
RATE_LIMIT_PER_MIN = int(os.getenv("RATE_LIMIT_PER_MIN", "10"))
# Overload protection: replies this pod streams from the model at once, how many may wait in line,
# and for how long. Beyond that, people get "busy, try again" at once instead of a 2-minute hang.
# dev, qa and prod share one Ollama (2 replies at a time), so keep the totals close to that.
CHAT_SLOTS = int(os.getenv("CHAT_SLOTS", "1"))
CHAT_QUEUE = int(os.getenv("CHAT_QUEUE", "4"))
CHAT_QUEUE_WAIT_SECONDS = float(os.getenv("CHAT_QUEUE_WAIT_SECONDS", "30"))
COOKIE_SECURE = os.getenv("COOKIE_SECURE", "false").lower() == "true"
# Public chat (Phase 9b): visitors of the Netlify site reach prod through the Raspberry Pi (Tailscale
# Funnel). The Pi adds X-QwenOps-Edge with this secret plus the visitor's address. Only then is the
# request treated as public: stricter limits, always guest mode, shorter replies. Empty = no public chat.
EDGE_SECRET = _read_secret("EDGE_SECRET")
PUBLIC_RATE_LIMIT_PER_MIN = int(os.getenv("PUBLIC_RATE_LIMIT_PER_MIN", "4"))      # per visitor
PUBLIC_CHATS_PER_MIN = int(os.getenv("PUBLIC_CHATS_PER_MIN", "30"))               # all public visitors
PUBLIC_MAX_TOKENS = int(os.getenv("PUBLIC_MAX_TOKENS", "256"))   # keeps replies inside Netlify's proxy limit

ALLOWED_THEMES = ["teal", "indigo", "rose", "amber", "emerald", "slate"]

if not SESSION_SECRET or len(SESSION_SECRET) < 32:
    raise RuntimeError("SESSION_SECRET must be set and at least 32 characters")
if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL must be set")
