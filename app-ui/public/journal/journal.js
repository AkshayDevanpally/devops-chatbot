// Error Journal: renders /journal/journal.json (built from docs/ at image build time) as a
// self-scrolling journal. Hover or focus the viewer to pause and scroll by hand; leave it
// and auto-scroll resumes. All text goes in with textContent: docs are never parsed as HTML.
const DATA_URL = "/journal/journal.json";
const POLL_MS = 5 * 60 * 1000;          // pick up a redeploy without a page reload
const END_PAUSE_MS = 2500;
const TOUCH_RESUME_MS = 5000;

const $ = id => document.getElementById(id);
const viewer = $("viewer"), list = $("entries"), pill = $("pill"), playBtn = $("play");
const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const STATUS = {
  fixed: { stamp: "FIXED", icon: "✅" },
  passed: { stamp: "PASSED", icon: "🎉" },
  open: { stamp: "OPEN", icon: "🔓" },
  "false-alarm": { stamp: "FALSE ALARM", icon: "🕵️" },
  noted: { stamp: "NOTED", icon: "📝" },
};
const LOUD = /\b(error|fatal|fail(ed|ure)?|denied|exceeded|severe|panic|forbidden|crashloop\w*|backoff|refused|timed out)\b/i;

let data = null, filter = "all", speed = 36;
try { const s = Number(localStorage.getItem("journal.speed")); if ([18, 36, 80].includes(s)) speed = s; } catch { /* no storage */ }

// ---------- small DOM helpers ----------
function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}
// `code` and **bold** inside doc text, still without innerHTML
function rich(tag, cls, text) {
  const n = el(tag, cls);
  String(text).split(/(`[^`]+`|\*\*[^*]+\*\*)/).forEach(seg => {
    if (!seg) return;
    if (seg.startsWith("`") && seg.endsWith("`") && seg.length > 1) n.append(el("code", null, seg.slice(1, -1)));
    else if (seg.startsWith("**") && seg.endsWith("**") && seg.length > 3) n.append(el("b", null, seg.slice(2, -2)));
    else n.append(seg);
  });
  return n;
}

// ---------- rendering ----------
function renderPart(p) {
  switch (p.type) {
    case "field": {
      const f = el("div", "j-field");
      f.append(el("span", "j-label", p.label), rich("p", null, p.text));
      return f;
    }
    case "list": {
      const wrap = el("div", "j-field");
      if (p.label) wrap.append(el("span", "j-label", p.label));
      const ul = el("ul");
      p.items.forEach(i => ul.append(rich("li", null, i)));
      wrap.append(ul);
      return wrap;
    }
    case "log": {
      const term = el("div", "term");
      const bar = el("div", "term-bar");
      bar.append(el("i"), el("i"), el("i"), el("span", null, "log"));
      const pre = el("pre");
      p.text.split("\n").forEach(line => {
        const span = el("span", LOUD.test(line) ? "loud" : null, line || " ");
        pre.append(span, "\n");
      });
      term.append(bar, pre);
      return term;
    }
    case "table": {
      const box = el("div", "scroll-x");
      const t = el("table", "dt j-table");
      const rows = p.rows || [];
      if (!p.fields && rows.length) {
        const tr = t.createTHead().insertRow();
        rows[0].forEach(c => tr.append(rich("th", null, c)));
      }
      const body = t.createTBody();
      (p.fields ? rows : rows.slice(1)).forEach(r => {
        const tr = body.insertRow();
        r.forEach((c, i) => { const td = rich("td", p.fields && i === 0 ? "j-key" : null, c); tr.append(td); });
      });
      box.append(t);
      return box;
    }
    case "subhead": return rich("h5", "j-sub", p.text);
    default: return rich("p", "j-text", p.text);
  }
}

function renderEntry(e, n) {
  const st = STATUS[e.status] || STATUS.noted;
  const a = el("article", `j-entry st-${e.status}`);
  a.dataset.status = e.status;
  const node = el("div", "j-node", e.emoji);
  node.setAttribute("aria-hidden", "true");
  const sheet = el("div", "j-sheet");
  const head = el("div", "j-head");
  head.append(el("span", "j-no", `#${n}`), rich("h4", null, e.title));
  const stamp = el("span", `j-stamp ${e.status}`, st.stamp);
  if (e.status_note) stamp.title = e.status_note;
  sheet.append(head, stamp);
  const meta = el("div", "j-meta");
  meta.append(el("span", "j-kind", `${e.emoji} ${e.kind}`));
  if (e.status_note) meta.append(el("span", "j-note", `${st.icon} ${e.status_note}`));
  sheet.append(meta);
  e.parts.forEach(p => sheet.append(renderPart(p)));
  a.append(node, sheet);
  return a;
}

function renderChapter(c) {
  const sec = el("section", "j-chapter");
  const head = el("header", "j-chapter-head");
  const counts = c.entries.reduce((m, e) => (m[e.status] = (m[e.status] || 0) + 1, m), {});
  const title = el("h3");
  title.append(el("span", "j-book", "📘"), c.title);
  const meta = el("div", "j-chapter-meta");
  meta.append(el("span", "j-file", c.file), el("span", null, `🗓️ ${c.date}`),
              el("span", null, `${c.entries.length} entries`));
  Object.entries(counts).forEach(([s, n]) => meta.append(el("span", `j-count ${s}`, `${(STATUS[s] || STATUS.noted).icon} ${n}`)));
  head.append(title, meta);
  if (c.intro) head.append(rich("p", "note small", c.intro));
  sec.append(head);
  c.entries.forEach((e, i) => sec.append(renderEntry(e, i + 1)));
  return sec;
}

function renderStats(d) {
  const all = d.chapters.flatMap(c => c.entries);
  const count = s => all.filter(e => e.status === s).length;
  const root = $("stats");
  root.textContent = "";
  [["💥", all.length, "incidents"], ["✅", count("fixed") + count("passed"), "fixed"], ["🔓", count("open"), "open"],
   ["🕵️", count("false-alarm"), "false alarms"], ["📄", d.chapters.length, "docs"]].forEach(([i, n, w]) => {
    const chip = el("span", "j-chip");
    chip.append(el("span", null, i), el("b", null, String(n)), ` ${w}`);
    root.append(chip);
  });
  const when = new Date(d.generated_at);
  root.append(el("span", "j-chip muted", `🕒 built ${isNaN(when) ? "—" : when.toLocaleString()}`));
}

let unrevealed = [];
function render(keepRatio) {
  const ratio = keepRatio ? viewer.scrollTop / Math.max(1, viewer.scrollHeight - viewer.clientHeight) : 0;
  list.textContent = "";
  if (!data || !data.chapters.length) {
    list.append(el("p", "muted j-loading", "📭 The journal is empty. Add a write-up to docs/ and it appears after the next deploy."));
    return;
  }
  data.chapters.forEach(c => list.append(renderChapter(c)));
  const end = el("div", "j-end");
  end.append(el("span", null, "🏁"), " End of the journal. Back to the top in a moment…");
  list.append(end);
  applyFilter();
  viewer.scrollTop = ratio * (viewer.scrollHeight - viewer.clientHeight);
  pos = viewer.scrollTop;

  unrevealed = [...list.querySelectorAll(".j-entry, .j-chapter-head")];
  if (reduced) { unrevealed.forEach(n => n.classList.add("seen")); unrevealed = []; }
  reveal();
}

// Rise-in animation: reveal everything above the bottom edge of the viewer. Checked every
// frame from the scroll loop (positions, not observers), so it also works for manual scrolling.
function reveal() {
  if (!unrevealed.length) return;
  const edge = viewer.scrollTop + viewer.clientHeight * 0.95;
  unrevealed = unrevealed.filter(n => {
    if (n.closest("[hidden]")) return true;
    if (n.offsetTop < edge) { n.classList.add("seen"); return false; }
    return true;
  });
}

function applyFilter() {
  const want = s => filter === "all" || s === filter || (filter === "fixed" && s === "passed");
  list.querySelectorAll(".j-entry").forEach(n => { n.hidden = !want(n.dataset.status); });
  list.querySelectorAll(".j-chapter").forEach(c => { c.hidden = !c.querySelector(".j-entry:not([hidden])"); });
}

// ---------- auto-scroll ----------
// Paused while any reason is active: hover, keyboard focus, touch, the Pause button, a hidden tab.
const reasons = new Set(reduced ? ["user"] : []);
let pos = 0, lastT = 0, endTimer = null;

function setPill() {
  const running = reasons.size === 0;
  pill.className = `j-pill ${running ? "run" : "stop"}`;
  pill.textContent = running ? "▶ Auto-scrolling"
    : reasons.has("user") ? (reduced ? "⏸ Auto-scroll off (reduced motion). Press Play to start" : "⏸ Paused. Press Play to resume")
    : reasons.has("hover") ? "⏸ Paused. Scroll freely; move the mouse away to resume"
    : reasons.has("touch") ? "⏸ Paused while you read"
    : "⏸ Paused";
  playBtn.textContent = reasons.has("user") ? "▶ Play" : "⏸ Pause";
  playBtn.setAttribute("aria-pressed", String(reasons.has("user")));
}
function pause(why) { reasons.add(why); setPill(); }
function resume(why) {
  reasons.delete(why);
  if (reasons.size === 0) pos = viewer.scrollTop;      // continue from wherever the reader left it
  setPill();
}

function tick(t) {
  const dt = lastT ? Math.min(0.1, (t - lastT) / 1000) : 0;
  lastT = t;
  const max = viewer.scrollHeight - viewer.clientHeight;
  if (reasons.size === 0 && !endTimer && max > 0) {
    pos = Math.min(max, pos + speed * dt);
    viewer.scrollTop = pos;
    if (pos >= max - 1) {
      endTimer = setTimeout(() => {
        viewer.scrollTo({ top: 0, behavior: reduced ? "auto" : "smooth" });
        setTimeout(() => { pos = viewer.scrollTop; endTimer = null; }, 1200);
      }, END_PAUSE_MS);
    }
  }
  $("progress").style.width = `${max > 0 ? (viewer.scrollTop / max) * 100 : 0}%`;
  reveal();
  requestAnimationFrame(tick);
}

viewer.addEventListener("mouseenter", () => pause("hover"));
viewer.addEventListener("mouseleave", () => resume("hover"));
document.documentElement.addEventListener("mouseleave", () => resume("hover"));   // pointer left the window
viewer.addEventListener("focusin", e => { if (e.target === viewer && viewer.matches(":focus-visible")) pause("focus"); });
viewer.addEventListener("focusout", () => resume("focus"));
let touchTimer = null;
const touched = () => { pause("touch"); clearTimeout(touchTimer); touchTimer = setTimeout(() => resume("touch"), TOUCH_RESUME_MS); };
viewer.addEventListener("touchstart", touched, { passive: true });
viewer.addEventListener("touchmove", touched, { passive: true });
document.addEventListener("visibilitychange", () => document.hidden ? pause("hidden") : resume("hidden"));
playBtn.addEventListener("click", () => reasons.has("user") ? resume("user") : pause("user"));

document.querySelectorAll("[data-filter]").forEach(b => b.addEventListener("click", () => {
  filter = b.dataset.filter;
  document.querySelectorAll("[data-filter]").forEach(x => x.classList.toggle("on", x === b));
  applyFilter();
  viewer.scrollTop = 0; pos = 0;
  reveal();
}));
document.querySelectorAll("[data-speed]").forEach(b => {
  b.classList.toggle("on", Number(b.dataset.speed) === speed);
  b.addEventListener("click", () => {
    speed = Number(b.dataset.speed);
    try { localStorage.setItem("journal.speed", String(speed)); } catch { /* no storage */ }
    document.querySelectorAll("[data-speed]").forEach(x => x.classList.toggle("on", x === b));
  });
});

// ---------- data ----------
function toast(text) {
  const t = $("toast");
  t.textContent = text; t.hidden = false;
  setTimeout(() => { t.hidden = true; }, 5000);
}
async function load(first) {
  try {
    const r = await fetch(DATA_URL, { cache: "no-cache" });
    if (!r.ok) throw new Error(r.status);
    const d = await r.json();
    if (!first && data && d.generated_at === data.generated_at) return;
    const added = data ? d.chapters.reduce((n, c) => n + c.entries.length, 0) - data.chapters.reduce((n, c) => n + c.entries.length, 0) : 0;
    data = d;
    renderStats(d);
    render(!first);
    if (!first) toast(added > 0 ? `📬 ${added} new entr${added === 1 ? "y" : "ies"} in the journal` : "📬 The journal was updated");
  } catch {
    if (first) {
      list.textContent = "";
      list.append(el("p", "muted j-loading", "📭 No journal data in this build. It's generated from docs/ when the UI image is built."));
    }
  }
}

setPill();
load(true);
setInterval(() => load(false), POLL_MS);
requestAnimationFrame(tick);
