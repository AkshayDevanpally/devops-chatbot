let picked = null;
const wrap = document.getElementById("swatches");
const ship = document.getElementById("ship");
const result = document.getElementById("result");

// Name the environment this page deploys to (chat-api decides it; the page only shows it).
(async () => {
  try {
    const env = (await (await fetch("/theme.json", { cache: "no-store" })).json()).env;
    if (["dev", "qa", "prod"].includes(env)) {
      document.querySelectorAll(".target-env").forEach(el => { el.textContent = env; });
      ship.textContent = `Ship it to ${env}`;
    }
  } catch { /* keep the generic wording */ }
})();

(async () => {
  let themes = Object.keys(THEME_COLORS);
  try { themes = (await (await api("/api/themes")).json()).themes || themes; } catch { /* fall back */ }
  if (SHOWCASE) result.textContent = "Colour deploys run through Jenkins on the home server, so shipping is off in this public copy. "
    + "On the home network the pick goes through validate → deploy dev → verify in about 40 seconds.";
  themes.forEach(name => {
    const s = document.createElement("div");
    s.className = "swatch";
    s.style.background = THEME_COLORS[name] || "#444";
    s.textContent = name;
    s.onclick = () => {
      document.querySelectorAll(".swatch").forEach(x => x.classList.remove("selected"));
      s.classList.add("selected");
      picked = name;
      ship.disabled = !!SHOWCASE;
    };
    wrap.appendChild(s);
  });
})();

ship.onclick = async () => {
  ship.disabled = true;
  const res = await api("/api/theme", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ color: picked }),
  });
  const d = await res.json().catch(() => ({}));
  if (res.status === 202) {
    result.textContent = `"${picked}" is on its way through the pipeline. Opening the Pipeline page…`;
    setTimeout(() => { location.href = "/pipeline/?job=theme-deploy"; }, 1500);
    return;
  } else if (res.status === 429) {
    result.textContent = "One colour change per 5 minutes. Try again shortly.";
  } else if (res.status === 409) {
    result.textContent = "A colour change is already on its way. Watch it on the Pipeline page.";
  } else if (res.status === 503) {
    result.textContent = "The pipeline isn't connected here (only in Kubernetes).";
  } else if (res.status === 422) {
    result.textContent = "That colour isn't allowed.";
  } else {
    result.textContent = d.detail || "Couldn't start the pipeline. Try again in a minute.";
  }
  ship.disabled = false;
};
