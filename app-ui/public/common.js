// Shared: API base, theme, nav highlight. API_BASE is "" when UI and API share a host
// (ingress / compose proxy). For Netlify, config.js sets window.API_BASE to the API URL.
const API_BASE = (window.API_BASE || "").replace(/\/$/, "");

async function api(path, opts = {}) {
  return fetch(`${API_BASE}${path}`, { credentials: "include", ...opts });
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
