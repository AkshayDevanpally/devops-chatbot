// Shared: API base, theme, nav highlight. API_BASE is "" when UI and API share a host
// (ingress / compose proxy). For Netlify, config.js sets window.API_BASE to the API URL.
const API_BASE = (window.API_BASE || "").replace(/\/$/, "");

// Public showcase (Netlify, Phase 9): there is no backend. config.js sets window.SHOWCASE = {taken}.
// Read-only dashboards get a snapshot taken from prod (app-ui/showcase/, scripts/20-showcase.sh);
// everything else gets a clear "only on the home server" answer. No request leaves for an API.
const SHOWCASE = window.SHOWCASE && typeof window.SHOWCASE === "object" ? window.SHOWCASE : null;
const LIVE_CHAT_PATHS = ["/api/chat", "/api/history", "/api/status", "/api/wake"];   // Phase 9b, through the Pi
const SHOWCASE_FILES = { "/api/pulse": q => `pulse-${["15m", "1h", "6h"].includes(q.get("range")) ? q.get("range") : "1h"}.json`,
                         "/api/capacity": () => "capacity.json", "/api/backups": () => "backups.json" };

function showcaseWhen() {
  const d = new Date(SHOWCASE && SHOWCASE.taken);
  return isNaN(d) ? "an earlier run" : d.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

async function api(path, opts = {}) {
  if (SHOWCASE) {
    const u = new URL(path, location.origin);
    if (SHOWCASE.liveChat && LIVE_CHAT_PATHS.includes(u.pathname)) return fetch(path, { credentials: "include", ...opts });
    const file = SHOWCASE_FILES[u.pathname];
    if (file && (opts.method || "GET") === "GET") return fetch(`/showcase/${file(u.searchParams)}`, { cache: "no-cache" });
    if (u.pathname === "/api/pipeline") return jsonResponse(200, { available: false, error: "public showcase: Jenkins runs on the home server" });
    return jsonResponse(503, { showcase: true, detail: "This public copy has no backend. The live app runs on a home server." });
  }
  return fetch(`${API_BASE}${path}`, { credentials: "include", ...opts });
}

function showcaseBar() {
  if (!SHOWCASE) return;
  const bar = document.createElement("div");
  bar.className = "showcase-bar";
  const b = document.createElement("b"); b.textContent = "Public showcase. ";
  const chat = SHOWCASE.liveChat
    ? "Chat is live: a small model on a 4-core home server answers (as a guest, nothing is saved). Colour deploys need the home network"
    : "QwenOps runs on a 4-core home server; this is a static copy. Chat and colour deploys need the home network";
  const t = document.createTextNode(`${chat}, Pulse, Capacity and Backups show a snapshot from ${showcaseWhen()}, and the Pipeline page plays a demo build. `);
  const a = document.createElement("a"); a.href = "/architecture/"; a.textContent = "How it all fits together";
  bar.append(b, t, a);
  const header = document.querySelector("header");
  if (header) header.after(bar);
}

const THEME_COLORS = {
  teal: "#0d9488", indigo: "#4f46e5", rose: "#e11d48",
  amber: "#d97706", emerald: "#059669", slate: "#475569",
};

async function applyTheme() {
  try {
    const t = await (await fetch("/theme.json", { cache: "no-store" })).json();
    if (THEME_COLORS[t.color]) document.documentElement.style.setProperty("--accent", THEME_COLORS[t.color]);
    const env = document.querySelector(".env");
    if (env && t.env) env.textContent = t.env;
  } catch { /* default theme */ }
}

function markNav() {
  const here = location.pathname.replace(/index\.html$/, "");
  document.querySelectorAll("header nav a").forEach(a => {
    if (a.getAttribute("href") === here) a.classList.add("active");
  });
}

applyTheme();
markNav();
showcaseBar();
