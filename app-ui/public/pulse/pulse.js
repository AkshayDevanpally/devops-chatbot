// Pulse: live resources and traffic. Polls /api/pulse every 5 s while the tab is visible.
// The server runs fixed Prometheus queries; this page only chooses the time range.
// Everything that comes from the server is written with textContent, never innerHTML.
const REFRESH_MS = 5000;
const RANGES = ["15m", "1h", "6h"];
const SVGNS = "http://www.w3.org/2000/svg";
const $ = id => document.getElementById(id);

let range = "15m";
try { const saved = localStorage.getItem("pulse.range"); if (RANGES.includes(saved)) range = saved; } catch { /* no storage */ }
let last = null;
let lastAt = 0;
let inflight = false;
let failed = false;

// ---------- formatting ----------
const none = v => v == null || Number.isNaN(v);
const fmt = {
  rate: v => none(v) ? "—" : v === 0 ? "0" : v < 10 ? v.toFixed(2) : v.toFixed(1),
  pct: v => none(v) ? "—" : `${(v * 100).toFixed(v > 0 && v < 0.1 ? 1 : 0)}%`,
  secs: v => none(v) ? "—" : v === 0 ? "0 s" : v < 1 ? `${Math.round(v * 1000)} ms` : `${v.toFixed(1)} s`,
  int: v => none(v) ? "—" : String(Math.round(v)),
  cores: v => none(v) ? "—" : v === 0 ? "0" : v < 1 ? `${Math.round(v * 1000)}m` : v.toFixed(2),
  mib: v => none(v) ? "—" : v >= 1073741824 ? `${(v / 1073741824).toFixed(2)} GiB` : `${Math.round(v / 1048576)} MiB`,
};
const timeLabel = t => new Date(t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
const timeLabelFull = t => new Date(t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });

// Status colours are only ever paired with an icon and a word.
const STATUS = { good: ["✓", "OK"], warning: ["!", "High"], critical: ["✕", "Critical"] };
const threshold = (warn, crit) => v => none(v) ? null : v >= crit ? "critical" : v >= warn ? "warning" : "good";

// ---------- tiles ----------
const TILES = [
  { id: "req", label: "Requests / s", hint: "API traffic, last minute", get: d => d.stats.requests_per_sec, f: fmt.rate },
  { id: "err", label: "Server errors", hint: "share of 5xx, last 5 min", get: d => d.stats.error_ratio, f: fmt.pct,
    status: threshold(0.01, 0.05) },
  { id: "p95", label: "Chat reply p95", hint: "full answer, last 5 min", get: d => d.stats.chat_p95_seconds, f: fmt.secs },
  { id: "ttft", label: "First word p50", hint: "time until text appears", get: d => d.stats.first_token_p50_seconds, f: fmt.secs },
  { id: "tok", label: "Tokens / s", hint: "model output speed", get: d => d.stats.tokens_per_sec, f: fmt.rate },
  { id: "live", label: "Replies streaming", hint: "right now", get: d => d.stats.active_chats, f: fmt.int },
  { id: "pods", label: "API pods up", hint: "seen by Prometheus", get: d => d.stats.api_pods_up, f: fmt.int },
  { id: "users", label: "Users with history", get: d => d.storage && d.storage.users,
    f: (v, d) => none(v) ? "—" : `${v} / ${d.storage.max_users}`,
    hintFrom: d => d.storage ? `${d.storage.chats} chats saved` : "database unreachable" },
  { id: "model", label: "Model", get: d => d.model, f: v => ({ ready: "Ready", model_loading: "Loading", waking: "Unreachable" })[v] || "—",
    status: v => ({ ready: "good", model_loading: "warning", waking: "critical" })[v] || null, hintFrom: () => "qwen2.5 via Ollama" },
  { id: "cpu", label: "Host CPU", hint: "whole server", get: d => d.stats.host_cpu_ratio, f: fmt.pct, meter: true,
    status: threshold(0.7, 0.9) },
  { id: "mem", label: "Host memory", hint: "whole server", get: d => d.stats.host_memory_ratio, f: fmt.pct, meter: true,
    status: threshold(0.75, 0.9) },
];

function buildTiles() {
  const root = $("tiles");
  TILES.forEach(t => {
    const el = document.createElement("div");
    el.className = "tile";
    el.id = `tile-${t.id}`;
    el.innerHTML = `<div class="label"></div><div class="value">—</div>
      <div class="meter" hidden><div class="fill"></div></div><div class="hint"></div>`;
    el.querySelector(".label").textContent = t.label;
    el.querySelector(".hint").textContent = t.hint || "";
    if (t.meter) el.querySelector(".meter").hidden = false;
    root.appendChild(el);
  });
}

function renderTiles(d) {
  TILES.forEach(t => {
    const el = $(`tile-${t.id}`);
    const v = t.get(d);
    const valueEl = el.querySelector(".value");
    valueEl.textContent = t.f(v, d);
    const st = t.status ? t.status(v) : null;
    if (st) {
      const badge = document.createElement("span");
      badge.className = `badge ${st}`;
      const icon = document.createElement("i");
      icon.textContent = STATUS[st][0];
      badge.append(icon, STATUS[st][1]);
      valueEl.append(" ", badge);
    }
    if (t.hintFrom) el.querySelector(".hint").textContent = t.hintFrom(d);
    if (t.meter) {
      const fill = el.querySelector(".fill");
      fill.style.width = `${Math.min(100, Math.max(0, (v || 0) * 100))}%`;
      fill.className = `fill ${st || ""}`;
    }
  });
}

// ---------- charts ----------
const CHARTS = [
  { key: "requests", title: "Requests per second", f: fmt.rate, note: "API only. Health checks and this page's refreshes are left out." },
  { key: "latency", title: "Chat reply time", f: fmt.secs, note: "How long a full answer takes. p95 = 95% of replies are faster." },
  { key: "tokens", title: "Model output (tokens / s)", f: fmt.rate, note: "Roughly words per second the model is writing." },
  { key: "cpu", title: "CPU by workload", f: fmt.cores, note: "In cores (500m = half a core)." },
  { key: "memory", title: "Memory by workload", f: fmt.mib, note: "Working set: memory the pods are actively using." },
];
const cards = {};

function buildCharts() {
  const root = $("charts");
  CHARTS.forEach(def => {
    const card = document.createElement("article");
    card.className = "card";
    card.innerHTML = `<div class="card-head"><h3></h3><span class="latest"></span></div>
      <p class="note small"></p><div class="legend"></div>
      <div class="plot"><div class="tip" role="tooltip" hidden></div></div>
      <details class="data"><summary>View as table</summary><div class="scroll-x"><table class="dt"></table></div></details>`;
    card.querySelector("h3").textContent = def.title;
    card.querySelector(".note").textContent = def.note;
    root.appendChild(card);
    cards[def.key] = card;
    card.hoverX = null;
  });
}

function niceMax(v) {
  if (!(v > 0)) return 1;
  const p = 10 ** Math.floor(Math.log10(v));
  const n = v / p;
  return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * p;
}

function svg(tag, attrs, parent) {
  const el = document.createElementNS(SVGNS, tag);
  for (const k in attrs) el.setAttribute(k, attrs[k]);
  if (parent) parent.appendChild(el);
  return el;
}

const lastValue = s => { for (let i = s.points.length - 1; i >= 0; i--) if (s.points[i][1] != null) return s.points[i][1]; return null; };

function swatch(i) { const s = document.createElement("span"); s.className = `sw s${i + 1}`; return s; }

function renderLegend(card, def, series) {
  const legend = card.querySelector(".legend");
  const latest = card.querySelector(".latest");
  legend.textContent = "";
  latest.textContent = "";
  if (series.length === 1) {               // one line: the title names it, show the latest value
    latest.textContent = def.f(lastValue(series[0]));
    return;
  }
  series.forEach((s, i) => {
    const item = document.createElement("span");
    item.className = "item";
    const val = document.createElement("b");
    val.textContent = def.f(lastValue(s));
    item.append(swatch(i), s.name, " ", val);
    legend.appendChild(item);
  });
}

function renderTable(card, def, series) {
  const table = card.querySelector("table");
  table.textContent = "";
  const times = [...new Set(series.flatMap(s => s.points.map(p => p[0])))].sort((a, b) => b - a).slice(0, 12);
  const head = table.createTHead().insertRow();
  ["Time", ...series.map(s => s.name)].forEach((h, i) => {
    const th = document.createElement("th"); th.textContent = h; if (i) th.className = "num"; head.appendChild(th);
  });
  const body = table.createTBody();
  const maps = series.map(s => new Map(s.points));
  times.forEach(t => {
    const row = body.insertRow();
    row.insertCell().textContent = timeLabelFull(t);
    maps.forEach(m => { const c = row.insertCell(); c.className = "num"; c.textContent = def.f(m.get(t)); });
  });
  if (!times.length) body.insertRow().insertCell().textContent = "No data yet";
}

function drawChart(def, d) {
  const card = cards[def.key];
  const series = (d.charts && d.charts[def.key]) || [];
  const plot = card.querySelector(".plot");
  const tip = card.querySelector(".tip");
  plot.querySelectorAll("svg, .empty").forEach(n => n.remove());
  tip.hidden = true;
  renderLegend(card, def, series);
  renderTable(card, def, series);

  const values = series.flatMap(s => s.points.map(p => p[1]).filter(v => v != null));
  if (!values.length) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = d.available ? "No data yet. Use the app and it will show up here." : "Waiting for Prometheus";
    plot.appendChild(empty);
    return;
  }

  const W = Math.max(plot.clientWidth, 260), H = 190;
  const m = { l: 56, r: 12, t: 10, b: 24 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const t0 = d.start, t1 = d.end;
  const ymax = niceMax(Math.max(...values));
  const x = t => m.l + ((t - t0) / (t1 - t0)) * iw;
  const y = v => m.t + ih - (v / ymax) * ih;

  const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img", "aria-label": def.title }, null);
  plot.insertBefore(root, tip);

  for (let i = 0; i <= 4; i++) {
    const v = (ymax * i) / 4, yy = y(v);
    svg("line", { x1: m.l, x2: W - m.r, y1: yy, y2: yy, class: i ? "grid" : "axis" }, root);
    svg("text", { x: m.l - 8, y: yy + 4, class: "tick", "text-anchor": "end" }, root).textContent = def.f(v);
  }
  for (let i = 0; i <= 3; i++) {
    const t = t0 + ((t1 - t0) * i) / 3;
    svg("text", { x: x(t), y: H - 6, class: "tick", "text-anchor": i === 0 ? "start" : i === 3 ? "end" : "middle" }, root)
      .textContent = timeLabel(t);
  }

  series.forEach((s, i) => {
    let path = "", pen = false;
    for (const [t, v] of s.points) {
      if (v == null) { pen = false; continue; }          // gaps stay gaps
      path += `${pen ? "L" : "M"}${x(t).toFixed(1)},${y(v).toFixed(1)}`;
      pen = true;
    }
    if (path) svg("path", { d: path, class: `ln s${i + 1}` }, root);
  });

  // hover: crosshair + dots + tooltip, snapped to the shared timestamps
  const cross = svg("line", { y1: m.t, y2: m.t + ih, class: "cross", visibility: "hidden" }, root);
  const dots = series.map((_, i) => svg("circle", { r: 4, class: `dot s${i + 1}`, visibility: "hidden" }, root));
  const hit = svg("rect", { x: m.l, y: m.t, width: iw, height: ih, class: "hit" }, root);
  const maps = series.map(s => new Map(s.points));

  const show = clientX => {
    const box = root.getBoundingClientRect();
    const px = (clientX - box.left) * (W / box.width);
    const k = Math.round(((Math.min(Math.max(px, m.l), m.l + iw) - m.l) / iw) * ((t1 - t0) / d.step));
    const t = t0 + k * d.step;
    const xx = x(t);
    cross.setAttribute("x1", xx); cross.setAttribute("x2", xx); cross.setAttribute("visibility", "visible");
    tip.textContent = "";
    const head = document.createElement("div"); head.className = "tip-time"; head.textContent = timeLabelFull(t); tip.appendChild(head);
    series.forEach((s, i) => {
      const v = maps[i].get(t);
      if (v == null) { dots[i].setAttribute("visibility", "hidden"); }
      else { dots[i].setAttribute("cx", xx); dots[i].setAttribute("cy", y(v)); dots[i].setAttribute("visibility", "visible"); }
      const row = document.createElement("div"); row.className = "tip-row";
      const name = document.createElement("span"); name.append(swatch(i), s.name);
      const val = document.createElement("b"); val.textContent = def.f(v);
      row.append(name, val); tip.appendChild(row);
    });
    tip.hidden = false;
    const scale = box.width / W;
    const left = xx * scale + 12;
    tip.style.left = `${left + tip.offsetWidth > box.width ? xx * scale - tip.offsetWidth - 12 : left}px`;
    tip.style.top = "8px";
  };
  const hide = () => { cross.setAttribute("visibility", "hidden"); dots.forEach(c => c.setAttribute("visibility", "hidden")); tip.hidden = true; };
  hit.addEventListener("pointermove", e => { card.hoverX = e.clientX; show(e.clientX); });
  hit.addEventListener("pointerleave", () => { card.hoverX = null; hide(); });
  if (card.hoverX != null) show(card.hoverX);   // keep the tooltip steady across refreshes
}

// ---------- pods table ----------
const AREA = { ai: "Model", data: "Database", monitoring: "Monitoring" };
function renderPods(d) {
  const body = $("pods");
  body.textContent = "";
  if (!d.pods || !d.pods.length) {
    const c = body.insertRow().insertCell(); c.colSpan = 4; c.className = "muted";
    c.textContent = d.available ? "No pod metrics yet (they need Kubernetes)." : "Waiting for Prometheus";
    return;
  }
  d.pods.forEach(p => {
    const row = body.insertRow();
    row.insertCell().textContent = AREA[p.namespace] || `App (${p.namespace.replace(/^chatbot-/, "")})`;
    row.insertCell().textContent = p.pod;
    const cpu = row.insertCell(); cpu.className = "num"; cpu.textContent = none(p.cpu) ? "—" : `${Math.round(p.cpu * 1000)}m`;
    const mem = row.insertCell(); mem.className = "num"; mem.textContent = fmt.mib(p.memory);
  });
}

// ---------- refresh loop ----------
function render(d) {
  $("no-prom").style.display = d.available ? "none" : "block";
  renderTiles(d);
  CHARTS.forEach(def => drawChart(def, d));
  renderPods(d);
}

function updateLive() {
  const el = $("live"), text = $("live-text");
  if (document.hidden) { el.className = "live"; text.textContent = "Paused while this tab is hidden"; return; }
  if (failed) { el.className = "live err"; text.textContent = "Can't reach the API, retrying…"; return; }
  if (!lastAt) return;
  const secs = Math.round((Date.now() - lastAt) / 1000);
  el.className = "live on";
  text.textContent = `Live · updated ${secs < 2 ? "just now" : `${secs} s ago`}`;
}

async function refresh() {
  if (inflight || document.hidden) return;
  inflight = true;
  try {
    const res = await api(`/api/pulse?range=${encodeURIComponent(range)}`, { cache: "no-store" });
    if (!res.ok) throw new Error(String(res.status));
    last = await res.json();
    lastAt = Date.now();
    failed = false;
    render(last);
  } catch {
    failed = true;
  } finally {
    inflight = false;
    updateLive();
  }
}

function setRange(r) {
  range = r;
  try { localStorage.setItem("pulse.range", r); } catch { /* no storage */ }
  document.querySelectorAll(".seg button").forEach(b => {
    const on = b.dataset.range === r;
    b.classList.toggle("on", on);
    b.setAttribute("aria-pressed", String(on));
  });
}

document.querySelectorAll(".seg button").forEach(b => b.addEventListener("click", () => { setRange(b.dataset.range); refresh(); }));
document.addEventListener("visibilitychange", () => { updateLive(); refresh(); });
let resizeTimer;
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => { if (last) CHARTS.forEach(def => drawChart(def, last)); }, 150);
});

buildTiles();
buildCharts();
setRange(range);
refresh();
setInterval(refresh, REFRESH_MS);
setInterval(updateLive, 1000);
