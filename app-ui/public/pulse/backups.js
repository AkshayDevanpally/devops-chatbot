// Pulse: the Backups panel. Reads /api/backups (chat-api asks backup-ops, which reads the backup
// CronJobs and Jobs). "Back up now" needs the admin password; the server checks it and limits guesses.
// Everything from the server is written with textContent, never innerHTML.
(() => {
  const $ = id => document.getElementById(id);
  const KIND = { backup: "Backup", offsite: "Off-site copy", "restore-test": "Restore test" };
  const STATE = { succeeded: ["good", "✓", "OK"], failed: ["critical", "✕", "Failed"], running: ["warning", "…", "Running"] };
  let data = null, timer = null, openLogs = new Set();

  const when = iso => iso ? new Date(iso).toLocaleString([], { weekday: "short", day: "numeric", month: "short",
    hour: "2-digit", minute: "2-digit" }) : "—";
  const ago = iso => {
    if (!iso) return "never";
    const m = Math.round((Date.now() - new Date(iso)) / 60000);
    return m < 1 ? "just now" : m < 60 ? `${m} min ago` : m < 2880 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} days ago`;
  };
  const took = r => r.started && r.finished ? `${Math.max(1, Math.round((new Date(r.finished) - new Date(r.started)) / 1000))} s` : "";

  function badge(state) {
    const [cls, icon, word] = STATE[state] || ["", "", state];
    const b = document.createElement("span"); b.className = `badge ${cls}`;
    const i = document.createElement("i"); i.textContent = icon; b.append(i, word);
    return b;
  }

  // Age check: the nightly backup should be under ~26 h old, the off-site copy under ~3.5 days.
  function tile(label, info, maxHours, runs, kind) {
    const el = document.createElement("div"); el.className = "tile";
    const lab = document.createElement("div"); lab.className = "label"; lab.textContent = label;
    const val = document.createElement("div"); val.className = "value";
    const hint = document.createElement("div"); hint.className = "hint";
    const lastRun = runs.find(r => r.kind === kind);
    if (!info || !info.configured) {
      val.textContent = "Not set up";
    } else {
      val.textContent = ago(info.last_success);
      const hours = info.last_success ? (Date.now() - new Date(info.last_success)) / 3600000 : Infinity;
      const failedLast = lastRun && lastRun.status === "failed";
      const st = failedLast ? "failed" : hours <= maxHours ? "succeeded" : null;
      if (st) val.append(" ", badge(st));
      else if (info.last_success || lastRun) { const b = badge("failed"); b.lastChild.textContent = "Overdue"; val.append(" ", b); }
      hint.textContent = info.next ? `next: ${when(info.next)}` : info.suspended ? "paused" : "";
    }
    el.append(lab, val, hint);
    return el;
  }

  async function loadLog(job, pre) {
    try {
      const res = await api(`/api/backups/log?job=${encodeURIComponent(job)}`, { cache: "no-store" });
      const d = await res.json();
      pre.textContent = res.ok ? d.log : (d.detail || "Log not available");
    } catch { pre.textContent = "Can't reach the API"; }
  }

  function runRow(r) {
    const det = document.createElement("details"); det.className = "bk-run"; det.dataset.job = r.job;
    const sum = document.createElement("summary");
    const what = document.createElement("span"); what.className = "what"; what.textContent = KIND[r.kind] || r.kind;
    const trig = document.createElement("span"); trig.className = "muted"; trig.textContent = r.trigger === "manual" ? "manual" : "scheduled";
    const time = document.createElement("span"); time.className = "when"; time.textContent = `${when(r.started)} ${took(r) ? "· " + took(r) : ""}`;
    sum.append(what, badge(r.status), trig, time);
    const term = document.createElement("div"); term.className = "term";
    const bar = document.createElement("div"); bar.className = "term-bar";
    bar.append(document.createElement("i"), document.createElement("i"), document.createElement("i"));
    const name = document.createElement("span"); name.textContent = r.job; bar.append(name);
    const pre = document.createElement("pre"); pre.textContent = "Loading…";
    term.append(bar, pre);
    det.append(sum, term);
    det.addEventListener("toggle", () => {
      if (det.open) { openLogs.add(r.job); loadLog(r.job, pre); } else openLogs.delete(r.job);
    });
    if (openLogs.has(r.job)) { det.open = true; loadLog(r.job, pre); }   // keep open logs open (and fresh) across refreshes
    return det;
  }

  function render(d) {
    const tiles = $("bk-tiles"), runs = $("bk-runs");
    tiles.textContent = ""; runs.textContent = "";
    if (d.available === false) {
      const p = document.createElement("p"); p.className = "muted";
      p.textContent = "Backup status isn't available here (it needs Kubernetes and backup-ops: make backups).";
      runs.append(p); $("bk-now").disabled = true; return;
    }
    const list = d.runs || [];
    tiles.append(tile("Last backup (on server)", d.backup, 26, list, "backup"),
                 tile("Last off-site copy (S3)", d.offsite, 84, list, "offsite"),
                 tile("Last restore test", d.restore_test, 24 * 8, list, "restore-test"));
    if (!list.length) { const p = document.createElement("p"); p.className = "muted"; p.textContent = "No runs kept yet."; runs.append(p); }
    list.forEach(r => runs.append(runRow(r)));
    const btn = $("bk-now");
    btn.disabled = !d.manual_enabled || d.running;
    btn.textContent = d.running ? "Backup running…" : "Back up now";
    btn.title = d.manual_enabled ? "" : "Set an admin password first: make backup-admin-password";
  }

  async function refresh() {
    if (document.hidden) return schedule();
    try {
      const res = await api("/api/backups", { cache: "no-store" });
      if (res.ok) { data = await res.json(); render(data); }
    } catch { /* keep the last view */ }
    schedule();
  }
  function schedule() { clearTimeout(timer); timer = setTimeout(refresh, data && data.running ? 4000 : 20000); }

  function msg(text, err) { const m = $("bk-msg"); m.textContent = text; m.className = `bk-msg${err ? " err" : ""}`; }

  $("bk-now").addEventListener("click", () => { $("bk-form").hidden = false; $("bk-pass").focus(); msg(""); });
  $("bk-cancel").addEventListener("click", () => { $("bk-form").hidden = true; $("bk-pass").value = ""; msg(""); });
  $("bk-form").addEventListener("submit", async e => {
    e.preventDefault();
    const pass = $("bk-pass").value;
    $("bk-pass").value = "";
    msg("Starting…");
    try {
      const res = await api("/api/backups/run", { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ password: pass }) });
      const d = await res.json().catch(() => ({}));
      if (res.status === 202) {
        $("bk-form").hidden = true;
        msg("Backup started. The off-site copy follows when it finishes. Open the run below to watch its log.");
        data = { ...(data || {}), running: true };
        setTimeout(refresh, 1500);
      } else {
        msg(d.detail || `Not started (${res.status})`, true);
      }
    } catch { msg("Can't reach the API", true); }
  });
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
  refresh();
})();
