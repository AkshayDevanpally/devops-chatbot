let picked = null;
const wrap = document.getElementById("swatches");
const ship = document.getElementById("ship");
const result = document.getElementById("result");

(async () => {
  let themes = Object.keys(THEME_COLORS);
  try { themes = (await (await api("/api/themes")).json()).themes; } catch { /* fall back */ }
  themes.forEach(name => {
    const s = document.createElement("div");
    s.className = "swatch";
    s.style.background = THEME_COLORS[name] || "#444";
    s.textContent = name;
    s.onclick = () => {
      document.querySelectorAll(".swatch").forEach(x => x.classList.remove("selected"));
      s.classList.add("selected");
      picked = name;
      ship.disabled = false;
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
  if (res.status === 202) {
    result.textContent = `Request accepted for "${picked}". Watch it on the Pipeline page.`;
    setTimeout(() => { location.href = "/pipeline/"; }, 1500);
  } else if (res.status === 429) {
    result.textContent = "One colour change per 5 minutes. Try again shortly.";
  } else {
    result.textContent = "That colour isn't allowed.";
  }
  ship.disabled = false;
};
