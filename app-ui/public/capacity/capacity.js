// Capacity page: home server (left) vs AWS (right). Reads /api/capacity only: fixed queries
// on the server, no PromQL from the browser. Text is set with textContent everywhere.
const REFRESH_MS = 10000;
const SVGNS = "http://www.w3.org/2000/svg";
const $ = id => document.getElementById(id);

const none = v => v == null || Number.isNaN(v);
const fmt = {
  pct: v => none(v) ? "—" : `${(v * 100).toFixed(v > 0 && v < 0.1 ? 1 : 0)}%`,
  int: v => none(v) ? "—" : String(Math.round(v)),
  cores: v => none(v) ? "—" : v === 0 ? "0" : v < 0.01 ? "<0.01" : v.toFixed(2),
  gib: v => none(v) ? "—" : `${(v / 1073741824).toFixed(1)} GiB`,
  mib: v => none(v) ? "—" : v >= 1073741824 ? `${(v / 1073741824).toFixed(2)} GiB` : `${Math.round(v / 1048576)} MiB`,
};
const timeLabel = t => new Date(t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

// Status colours always come with an icon and a word.
const STATUS = { good: ["✓", "OK"], warning: ["!", "High"], critical: ["✕", "Critical"] };
const threshold = (warn, crit) => v => none(v) ? null : v >= crit ? "critical" : v >= warn ? "warning" : "good";

function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}
function svg(tag, attrs, parent) {
  const n = document.createElementNS(SVGNS, tag);
  for (const k in attrs) n.setAttribute(k, attrs[k]);
  if (parent) parent.appendChild(n);
  return n;
}

// ---------- tiles ----------
function tile({ label, value, hint, ratio, status }) {
  const t = el("div", "tile");
  t.append(el("div", "label", label));
  const v = el("div", "value", value);
  if (status) {
    const [icon, word] = STATUS[status];
    const b = el("span", `badge ${status}`);
    b.append(el("i", null, icon), word);
    v.append(" ", b);
  }
  t.append(v);
  if (ratio != null) {
    const m = el("div", "meter");
    const f = el("div", `fill ${status || ""}`);
    f.style.width = `${Math.min(100, Math.max(0, ratio * 100))}%`;
    m.append(f);
    t.append(m);
  }
  if (hint) t.append(el("div", "hint", hint));
  return t;
}

function renderLocalTiles(L) {
  const root = $("local-tiles");
  root.textContent = "";
  const burstAt = L.prod_burst_at || 3;
  const pods = L.prod_api_pods;
  root.append(
    tile({ label: "CPU", value: fmt.pct(L.cpu_ratio), ratio: L.cpu_ratio, status: threshold(0.7, 0.9)(L.cpu_ratio),
           hint: none(L.cpu_cores) ? "of the server" : `of ${fmt.int(L.cpu_cores)} cores` }),
    tile({ label: "Memory", value: fmt.pct(L.memory_ratio), ratio: L.memory_ratio,
           status: threshold(0.75, 0.9)(L.memory_ratio),
           hint: `${fmt.gib(L.memory_used_bytes)} of ${fmt.gib(L.memory_total_bytes)}` +
                 (L.swap_bytes > 0 ? ` · swap ${fmt.mib(L.swap_bytes)}` : "") }),
    tile({ label: "Pods running", value: fmt.int(L.pods), hint: "all namespaces" }),
    tile({ label: "Prod API pods", value: none(pods) ? "—" : `${fmt.int(pods)} / ${burstAt}`,
           ratio: none(pods) ? null : pods / burstAt,
           // prod normally runs 2; only "High" once it reaches the local ceiling (the burst point)
           status: none(pods) ? null : pods >= burstAt ? "warning" : "good",
           hint: `AWS burst starts at ${burstAt}` }),
  );
  $("local-sub").textContent = none(L.cpu_cores)
    ? "Home server running k3s"
    : `Home server running k3s · ${fmt.int(L.cpu_cores)} cores · ${fmt.gib(L.memory_total_bytes)}`;
}

// ---------- line chart (shared by both halves) ----------
// series: [{name, points:[[t, v]]}], values are ratios 0..1 on one axis (never two scales).
function lineChart(card, series, d, emptyText) {
  const plot = card.querySelector(".plot");
  const tip = card.querySelector(".tip");
  const legend = card.querySelector(".legend");
  plot.querySelectorAll("svg, .empty").forEach(n => n.remove());
  tip.hidden = true;

  const lastValue = s => { for (let i = s.points.length - 1; i >= 0; i--) if (s.points[i][1] != null) return s.points[i][1]; return null; };
  const swatch = i => el("span", `sw s${i + 1}`);
  if (legend) {
    legend.textContent = "";
    if (series.length > 1) series.forEach((s, i) => {
      const item = el("span", "item");
      item.append(swatch(i), s.name, " ", el("b", null, fmt.pct(lastValue(s))));
      legend.append(item);
    });
  }
  const table = card.querySelector("table");
  if (table) {
    table.textContent = "";
    const times = [...new Set(series.flatMap(s => s.points.map(p => p[0])))].sort((a, b) => b - a).slice(0, 12);
    const head = table.createTHead().insertRow();
    ["Time", ...series.map(s => s.name)].forEach((h, i) => { const th = el("th", i ? "num" : "", h); head.append(th); });
    const body = table.createTBody();
    const maps = series.map(s => new Map(s.points));
    times.forEach(t => {
      const r = body.insertRow();
      r.insertCell().textContent = new Date(t * 1000).toLocaleTimeString();
      maps.forEach(m => { const c = r.insertCell(); c.className = "num"; c.textContent = fmt.pct(m.get(t)); });
    });
    if (!times.length) body.insertRow().insertCell().textContent = "No data yet";
  }

  const values = series.flatMap(s => s.points.map(p => p[1]).filter(v => v != null));
  if (!values.length) { plot.append(el("div", "empty", emptyText)); return; }

  const W = Math.max(plot.clientWidth, 260), H = 170;
  const m = { l: 44, r: 12, t: 10, b: 24 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const t0 = d.start, t1 = d.end;
  const ymax = Math.max(1, ...values) > 1 ? Math.ceil(Math.max(...values) * 10) / 10 : 1;   // 100% unless above
  const x = t => m.l + ((t - t0) / (t1 - t0)) * iw;
  const y = v => m.t + ih - (v / ymax) * ih;
  const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img",
                            "aria-label": card.querySelector("h3").textContent }, null);
  plot.insertBefore(root, tip);

  for (let i = 0; i <= 4; i++) {
    const v = (ymax * i) / 4, yy = y(v);
    svg("line", { x1: m.l, x2: W - m.r, y1: yy, y2: yy, class: i ? "grid" : "axis" }, root);
    svg("text", { x: m.l - 8, y: yy + 4, class: "tick", "text-anchor": "end" }, root).textContent = fmt.pct(v);
  }
  for (let i = 0; i <= 3; i++) {
    const t = t0 + ((t1 - t0) * i) / 3;
    svg("text", { x: x(t), y: H - 6, class: "tick", "text-anchor": i === 0 ? "start" : i === 3 ? "end" : "middle" }, root)
      .textContent = timeLabel(t);
  }
  series.forEach((s, i) => {
    let path = "", pen = false;
    for (const [t, v] of s.points) {
      if (v == null) { pen = false; continue; }
      path += `${pen ? "L" : "M"}${x(t).toFixed(1)},${y(v).toFixed(1)}`;
      pen = true;
    }
    if (path) svg("path", { d: path, class: `ln s${i + 1}` }, root);
  });

  const cross = svg("line", { y1: m.t, y2: m.t + ih, class: "cross", visibility: "hidden" }, root);
  const dots = series.map((_, i) => svg("circle", { r: 4, class: `dot s${i + 1}`, visibility: "hidden" }, root));
  const hit = svg("rect", { x: m.l, y: m.t, width: iw, height: ih, class: "hit" }, root);
  const maps = series.map(s => new Map(s.points));
  const show = clientX => {
    const box = root.getBoundingClientRect();
    const px = (clientX - box.left) * (W / box.width);
    const k = Math.round(((Math.min(Math.max(px, m.l), m.l + iw) - m.l) / iw) * ((t1 - t0) / d.step));
    const t = t0 + k * d.step, xx = x(t);
    cross.setAttribute("x1", xx); cross.setAttribute("x2", xx); cross.setAttribute("visibility", "visible");
    tip.textContent = "";
    tip.append(el("div", "tip-time", new Date(t * 1000).toLocaleTimeString()));
    series.forEach((s, i) => {
      const v = maps[i].get(t);
      if (v == null) dots[i].setAttribute("visibility", "hidden");
      else { dots[i].setAttribute("cx", xx); dots[i].setAttribute("cy", y(v)); dots[i].setAttribute("visibility", "visible"); }
      const row = el("div", "tip-row");
      const name = el("span"); name.append(swatch(i), s.name);
      row.append(name, el("b", null, fmt.pct(v)));
      tip.append(row);
    });
    tip.hidden = false;
    const scale = box.width / W, left = xx * scale + 12;
    tip.style.left = `${left + tip.offsetWidth > box.width ? xx * scale - tip.offsetWidth - 12 : left}px`;
  };
  hit.addEventListener("pointermove", e => { card.hoverX = e.clientX; show(e.clientX); });
  hit.addEventListener("pointerleave", () => {
    card.hoverX = null; cross.setAttribute("visibility", "hidden");
    dots.forEach(c => c.setAttribute("visibility", "hidden")); tip.hidden = true;
  });
  if (card.hoverX != null) show(card.hoverX);
}

// ---------- namespace bars (one hue: magnitude, not identity) ----------
const NS_LABEL = {
  ai: "Model (Ollama)", data: "Database", monitoring: "Monitoring", ci: "Jenkins",
  "cert-manager": "Certificates", "kube-system": "Kubernetes system",
  "chatbot-dev": "App · dev", "chatbot-qa": "App · qa", "chatbot-prod": "App · prod",
};
function renderBars(rows, totalMem) {
  const root = $("ns-bars");
  root.textContent = "";
  if (!rows.length) { root.append(el("li", "muted", "No data yet")); return; }
  const max = Math.max(...rows.map(r => r.memory_bytes || 0), 1);
  let sum = 0;
  rows.forEach(r => {
    sum += r.memory_bytes || 0;
    const li = el("li", "bar-row");
    li.title = `${r.namespace}: ${fmt.mib(r.memory_bytes)} memory, ${fmt.cores(r.cpu_cores)} CPU cores`;
    const name = el("span", "bar-name");
    name.append(el("b", null, NS_LABEL[r.namespace] || r.namespace), el("small", null, r.namespace));
    const track = el("span", "bar-track");
    const fill = el("span", "bar-fill");
    fill.style.width = `${((r.memory_bytes || 0) / max) * 100}%`;
    track.append(fill);
    li.append(name, track, el("span", "bar-val", fmt.mib(r.memory_bytes)), el("span", "bar-cpu", fmt.cores(r.cpu_cores)));
    root.append(li);
  });
  $("ns-total").textContent = totalMem ? `${fmt.mib(sum)} in pods` : "";
}

// ---------- AWS half ----------
function awsState(chip, running, text) {
  chip.className = `chip small ${running ? "on" : ""}`;
  chip.textContent = text;
}
function awsEmpty(body, icon, title, lines) {
  body.textContent = "";
  const box = el("div", "aws-empty");
  box.append(el("div", "aws-empty-icon", icon), el("div", "aws-empty-title", title));
  lines.forEach(l => box.append(el("p", "note small", l)));
  body.append(box);
}
function awsRunning(body, tiles, series, d, chartTitle) {
  body.textContent = "";
  const grid = el("div", "tiles tiles-3");
  tiles.forEach(t => grid.append(tile(t)));
  const card = el("div", "mini-chart");
  card.innerHTML = `<h3 class="sr-only"></h3><div class="plot"><div class="tip" role="tooltip" hidden></div></div>`;
  card.querySelector("h3").textContent = chartTitle;
  body.append(grid, card);
  lineChart(card, [{ name: chartTitle, points: series }], d, "No history yet");
}

function renderAws(A, d) {
  const burst = $("aws-burst");
  if (A.burst.running) {
    awsState(burst.querySelector("[data-state]"), true, `● ${A.burst.nodes} node${A.burst.nodes === 1 ? "" : "s"}`);
    awsRunning(burst.querySelector(".aws-body"), [
      { label: "Nodes", value: fmt.int(A.burst.nodes), hint: "in AWS" },
      { label: "CPU", value: fmt.pct(A.burst.cpu_ratio), ratio: A.burst.cpu_ratio, status: threshold(0.7, 0.9)(A.burst.cpu_ratio) },
      { label: "Memory", value: fmt.pct(A.burst.memory_ratio), ratio: A.burst.memory_ratio, status: threshold(0.75, 0.9)(A.burst.memory_ratio) },
    ], A.burst.series, d, "Burst CPU, last hour");
  } else {
    awsState(burst.querySelector("[data-state]"), false, "○ Scaled to zero");
    awsEmpty(burst.querySelector(".aws-body"), "💤", "Nothing running · $0/h", [
      "Created with Terraform when prod needs more than the home server's API pods, and destroyed again when load drops.",
    ]);
  }
  const anything = A.burst.running;
  const chip = $("aws-state");
  chip.className = `chip ${anything ? "on" : ""}`;
  chip.textContent = anything ? "● In use" : "○ Nothing running · $0/h";
}

// ---------- refresh loop ----------
let last = null, failed = false, lastAt = 0;
function updateLive() {
  const live = $("live"), text = $("live-text");
  if (failed) { live.className = "live err"; text.textContent = last ? "Connection lost, retrying" : "Can't reach the API"; return; }
  if (!last) return;
  if (STATIC) { live.className = "live"; text.textContent = `Snapshot from ${showcaseWhen()}`; return; }
  live.className = "live on";
  text.textContent = `Updated ${Math.max(0, Math.round((Date.now() - lastAt) / 1000))}s ago`;
}
function render(d) {
  $("no-prom").style.display = d.available ? "none" : "block";
  renderLocalTiles(d.local || {});
  const s = (d.local && d.local.series) || {};
  lineChart($("local-chart"), [{ name: "CPU", points: s.cpu || [] }, { name: "Memory", points: s.memory || [] }],
            d, d.available ? "No data yet" : "Waiting for Prometheus");
  renderBars((d.local && d.local.namespaces) || [], d.local && d.local.memory_total_bytes);
  renderAws(d.aws, d);
}

async function refresh() {
  if (document.hidden) return;
  try {
    const r = await api("/api/capacity", { cache: "no-store" });
    if (!r.ok) throw new Error(r.status);
    const d = await r.json();
    last = d; lastAt = Date.now(); failed = false;
    render(d);
  } catch { failed = true; }
  updateLive();
}

refresh();
setInterval(refresh, REFRESH_MS);
setInterval(updateLive, 1000);
document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
let resizeTimer;
window.addEventListener("resize", () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(() => last && render(last), 200); });   // redraw only, no extra API call
