// Shared: API base, theme, nav highlight. API_BASE is "" when UI and API share a host
// (ingress / compose proxy). For Netlify, config.js sets window.API_BASE to the API URL.
const API_BASE = (window.API_BASE || "").replace(/\/$/, "");

// Public site (Netlify). config.js sets window.SHOWCASE = {taken, live}.
// - live (Phase 9b): the pages use the home server for real, through the Raspberry Pi; only
//   "Back up now" stays home-only (the Pi and chat-api refuse it).
// - not live (Phase 9): a static copy. Pulse, Capacity and Backups read a snapshot taken from prod
//   (app-ui/showcase/, scripts/20-showcase.sh), the rest says "only on the home server".
const SHOWCASE = window.SHOWCASE && typeof window.SHOWCASE === "object" ? window.SHOWCASE : null;
const LIVE = !!(SHOWCASE && SHOWCASE.live);
const STATIC = !!SHOWCASE && !LIVE;
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
  if (STATIC) {
    const u = new URL(path, location.origin);
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
  const b = document.createElement("b");
  const t = document.createTextNode("");
  if (LIVE) {
    b.textContent = "Live from a home server. ";
    t.textContent = "Everything here runs on a 4-core machine at home (Be a Dev changes the real prod colour). "
      + "If it's asleep it wakes in about a minute. Chats are saved: the last 15 for each of the latest 50 visitors. ";
  } else {
    b.textContent = "Public showcase. ";
    t.textContent = `QwenOps runs on a 4-core home server; this is a static copy. Chat and colour deploys need the home network, `
      + `Pulse, Capacity and Backups show a snapshot from ${showcaseWhen()}, and the Pipeline page plays a demo build. `;
  }
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
