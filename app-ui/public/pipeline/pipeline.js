// Pipeline page. Live: real Jenkins builds from /api/pipeline (chat-api asks pipeline-events, which reads
// Jenkins as a read-and-start-only account), refreshed every 3 s while something runs. Demo: a simulated
// build when Jenkins isn't connected (Docker Compose). Server text is written with textContent only.
const $ = id => document.getElementById(id);
const JOBS = ["chatbot", "theme-deploy"];
const ICONS = {
  "Checkout": "📦", "Build": "🏭", "Test": "🔍", "Security scan": "🩻", "Sign & box": "🎁",
  "Deploy dev": "🧪", "Deploy qa": "✅", "Ship to prod": "🚚", "Validate": "🎨", "Verify": "🔎",
};
// Jenkins status -> station look. Colours always come with a word.
const LOOK = {
  SUCCESS: ["passed", "passed"], FAILED: ["failed", "failed"], UNSTABLE: ["failed", "unstable"],
  IN_PROGRESS: ["running", "running"], PAUSED_PENDING_INPUT: ["waiting", "waiting for approval"],
  ABORTED: ["aborted", "stopped"], NOT_EXECUTED: ["skipped", "skipped"], PENDING: ["", "pending"],
};
const RUN_BADGE = {
  SUCCESS: ["good", "✓", "Passed"], FAILED: ["critical", "✕", "Failed"], UNSTABLE: ["warning", "!", "Unstable"],
  IN_PROGRESS: ["warning", "…", "Running"], PAUSED_PENDING_INPUT: ["warning", "⏸", "Waiting for approval"],
  ABORTED: ["", "■", "Stopped"], NOT_EXECUTED: ["", "–", "Not run"],
};

const params = new URLSearchParams(location.search);
let job = JOBS.includes(params.get("job")) ? params.get("job") : "chatbot";
let picked = null;          // run number chosen by the user; null = follow the newest
let data = null, timer = null, lastAt = 0, failed = false;
let open = null;            // { build, stage, name } of the log drawer

const ago = iso => {
  if (!iso) return "";
  const m = Math.round((Date.now() - new Date(iso)) / 60000);
  return m < 1 ? "just now" : m < 60 ? `${m} min ago` : m < 2880 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} days ago`;
};
const dur = ms => ms == null ? "" : ms < 60000 ? `${Math.round(ms / 1000)} s` : `${Math.floor(ms / 60000)} min ${Math.round((ms % 60000) / 1000)} s`;
function badge(status) {
  const [cls, icon, word] = RUN_BADGE[status] || ["", "", status || ""];
  const b = document.createElement("span"); b.className = `badge ${cls}`;
  const i = document.createElement("i"); i.textContent = icon; b.append(i, word);
  return b;
}

// ---------- live ----------
function stagesFor(run, runs) {
  // Jenkins lists only stages that have started: fill the rest from the newest finished run, as pending.
  const done = runs.find(r => r !== run && ["SUCCESS", "FAILED", "UNSTABLE", "ABORTED"].includes(r.status));
  const names = run.stages.map(s => s.name);
  const rest = done ? done.stages.filter(s => !names.includes(s.name)).map(s => ({ name: s.name, status: "PENDING" })) : [];
  return [...run.stages, ...(["IN_PROGRESS", "PAUSED_PENDING_INPUT"].includes(run.status) ? rest : [])]
    .filter(s => !s.name.startsWith("Declarative:"));
}

function renderLive() {
  const runs = data.runs || [];
  const runsEl = $("runs"); runsEl.textContent = "";
  if (!runs.length) {
    $("run-head").hidden = true; $("factory").textContent = "";
    runsEl.textContent = job === "theme-deploy" ? "No colour deploys yet: pick a colour on Be a Dev." : "No builds yet.";
    return;
  }
  const run = runs.find(r => r.number === picked) || runs[0];
  runs.forEach(r => {
    const b = document.createElement("button"); b.type = "button";
    b.className = `run-chip ${r === run ? "on" : ""} st-${(LOOK[r.status] || ["", ""])[0]}`;
    b.textContent = `#${r.number}${r.color ? " · " + r.color : ""}`;
    b.title = `${(RUN_BADGE[r.status] || ["", "", r.status])[2]} · ${ago(r.started)}`;
    b.onclick = () => { picked = r === runs[0] ? null : r.number; renderLive(); };
    runsEl.appendChild(b);
  });

  $("run-head").hidden = false;
  $("run-name").textContent = `${job === "chatbot" ? "Build" : "Colour deploy"} #${run.number}`;
  $("run-badge").textContent = ""; $("run-badge").append(badge(run.status));
  const meta = [];
  if (run.color) meta.push(`colour: ${run.color}`);
  if (run.commit) meta.push(`commit ${run.commit}`);
  if (run.started) meta.push(`started ${ago(run.started)}`);
  if (run.duration_ms) meta.push(run.status === "IN_PROGRESS" ? `running ${dur(run.duration_ms)}` : `took ${dur(run.duration_ms)}`);
  $("run-meta").textContent = meta.join(" · ");
  const w = $("waiting");
  w.hidden = run.status !== "PAUSED_PENDING_INPUT";
  w.textContent = `⏸ ${run.waiting_for || "Waiting for approval"} An admin approves in Jenkins ("Ship it").`;

  const stages = stagesFor(run, runs);
  const f = $("factory"); f.textContent = "";
  let at = 0;
  stages.forEach((s, i) => {
    const [cls, word] = LOOK[s.status] || ["", (s.status || "").toLowerCase()];
    if (["running", "waiting", "failed"].includes(cls) || (cls === "passed" && i >= at)) at = i;
    const el = document.createElement("div");
    el.className = `station ${cls}`;
    el.innerHTML = `<div class="icon"></div><div class="name"></div><div class="st"></div>`;
    el.querySelector(".icon").textContent = ICONS[s.name] || "⚙️";
    el.querySelector(".name").textContent = s.name;
    el.querySelector(".st").textContent = s.duration_ms && cls !== "running" ? `${word} · ${dur(s.duration_ms)}` : word;
    if (s.id) {
      el.tabIndex = 0; el.setAttribute("role", "button");
      const show = () => openLog(run.number, s.id, s.name);
      el.onclick = show; el.onkeydown = e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); show(); } };
    } else el.classList.add("future");
    f.appendChild(el);
  });
  $("box").style.left = `calc(${(at / Math.max(1, stages.length - 1)) * 100}% - ${at ? 26 : 0}px)`;
  if (open && open.build === run.number) loadLog();
}

async function openLog(build, stage, name) {
  open = { build, stage, name };
  $("drawer").style.display = "block";
  $("drawer-title").textContent = `Logs: #${build} ${name}`;
  $("drawer-log").textContent = "Loading…";
  await loadLog();
}

async function loadLog() {
  if (!open) return;
  try {
    const r = await api(`/api/pipeline/log?job=${encodeURIComponent(job)}&build=${open.build}&stage=${open.stage}`, { cache: "no-store" });
    const d = await r.json();
    const pre = $("drawer-log"), atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
    pre.textContent = r.ok ? d.log : (d.detail || "Log not available");
    if (atEnd) pre.scrollTop = pre.scrollHeight;
  } catch { $("drawer-log").textContent = "Can't reach the API"; }
}

function live(on) {
  const el = $("live"), t = $("live-text");
  if (document.hidden) { el.className = "live"; t.textContent = "Paused while this tab is hidden"; return; }
  if (failed) { el.className = "live err"; t.textContent = "Can't reach the API, retrying…"; return; }
  if (!on || !lastAt) return;
  const s = Math.round((Date.now() - lastAt) / 1000);
  el.className = "live on"; t.textContent = `Live from Jenkins · updated ${s < 2 ? "just now" : `${s} s ago`}`;
}

async function refresh() {
  clearTimeout(timer);
  if (document.hidden) return;
  try {
    const r = await api(`/api/pipeline?job=${job}`, { cache: "no-store" });
    if (!r.ok) throw new Error(String(r.status));
    const d = await r.json();
    failed = false;
    if (d.available === false) return demoMode(d.error);
    data = d; lastAt = Date.now();
    $("mode").textContent = job === "chatbot"
      ? "Live: every push to master is built, tested, scanned and promoted dev → qa → prod (an admin approves prod)."
      : "Live: colour changes from Be a Dev, deployed to dev.";
    $("jobs").hidden = false; $("run").hidden = true;
    renderLive();
  } catch { failed = true; }
  live(true);
  const busy = data && (data.runs || []).some(r => ["IN_PROGRESS", "PAUSED_PENDING_INPUT"].includes(r.status));
  timer = setTimeout(refresh, busy ? 3000 : 10000);
}

function setJob(j) {
  job = j; picked = null; open = null; $("drawer").style.display = "none";
  document.querySelectorAll("#jobs button").forEach(b => {
    b.classList.toggle("on", b.dataset.job === j); b.setAttribute("aria-pressed", String(b.dataset.job === j));
  });
  const u = new URL(location.href); u.searchParams.set("job", j); history.replaceState(null, "", u);
  refresh();
}

// ---------- demo (no Jenkins connected) ----------
const DEMO = [
  ["Checkout", ["Cloning repo…", "HEAD is now at 3f2a9c1"]],
  ["Build", ["docker build --target runtime .", "Successfully built chat-api:3f2a9c1"]],
  ["Test", ["pytest -q", "22 passed in 3.6s"]],
  ["Security scan", ["trivy image chat-api:3f2a9c1", "HIGH: 0  CRITICAL: 0"]],
  ["Sign & box", ["SBOM -> sbom/chat-api-3f2a9c1.spdx.json", "pushed localhost:5000/chat-api:3f2a9c1"]],
  ["Deploy dev", ["helm upgrade --install chatbot-dev --atomic", "verify: passed"]],
  ["Deploy qa", ["helm upgrade --install chatbot-qa --atomic", "verify: passed"]],
  ["Ship to prod", ["Approved by admin", "helm upgrade --install chatbot-prod --atomic", "live"]],
];
const demoLogs = {};
function demoMode(reason) {
  $("mode").textContent = `Demo: a simulated build (${reason || "Jenkins isn't connected here"}).`;
  $("jobs").hidden = true; $("runs").textContent = ""; $("run-head").hidden = true; $("run").hidden = false;
  live(false); $("live-text").textContent = "";
  const f = $("factory");
  if (f.dataset.demo) return;
  f.dataset.demo = "1"; f.textContent = "";
  DEMO.forEach(([name], i) => {
    const el = document.createElement("div");
    el.className = "station"; el.id = `demo-${i}`;
    el.innerHTML = `<div class="icon"></div><div class="name"></div><div class="st">pending</div>`;
    el.querySelector(".icon").textContent = ICONS[name]; el.querySelector(".name").textContent = name;
    el.onclick = () => { $("drawer").style.display = "block"; $("drawer-title").textContent = `Logs: ${name}`; $("drawer-log").textContent = (demoLogs[i] || []).join("\n") || "(no output yet)"; };
    f.appendChild(el);
  });
}
$("run").onclick = async () => {
  $("run").disabled = true;
  DEMO.forEach((_, i) => { demoLogs[i] = []; $(`demo-${i}`).className = "station"; $(`demo-${i}`).querySelector(".st").textContent = "pending"; });
  for (const [i, [, lines]] of DEMO.entries()) {
    const el = $(`demo-${i}`); el.className = "station running"; el.querySelector(".st").textContent = "running";
    $("box").style.left = `calc(${(i / (DEMO.length - 1)) * 100}% - ${i ? 26 : 0}px)`;
    for (const line of lines) { await new Promise(r => setTimeout(r, 500 + Math.random() * 600)); demoLogs[i].push(line); }
    el.className = "station passed"; el.querySelector(".st").textContent = "passed";
  }
  $("run").disabled = false;
};

// ---------- wiring ----------
document.querySelectorAll("#jobs button").forEach(b => b.addEventListener("click", () => setJob(b.dataset.job)));
$("drawer-close").onclick = () => { open = null; $("drawer").style.display = "none"; };
document.addEventListener("visibilitychange", () => { live(true); if (!document.hidden) refresh(); });
setInterval(() => live(!!data), 1000);
setInterval(() => { if (open && data) { const r = (data.runs || []).find(x => x.number === open.build); if (r && ["IN_PROGRESS", "PAUSED_PENDING_INPUT"].includes(r.status)) loadLog(); } }, 3000);
setJob(job);
