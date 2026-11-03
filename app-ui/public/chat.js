const ORDER = ["waking", "cluster_ready", "model_loading", "ready"];
const logEl = document.getElementById("log");

function setStep(state) {
  const idx = ORDER.indexOf(state);
  document.querySelectorAll(".step").forEach(el => {
    const i = ORDER.indexOf(el.dataset.s);
    el.className = "step" + (i < idx ? " done" : i === idx ? " now" : "");
  });
}

function bubble(role, text = "") {
  const div = document.createElement("div");
  div.className = `msg ${role}`;
  div.textContent = text;   // textContent, never innerHTML: model output is untrusted
  logEl.appendChild(div);
  window.scrollTo(0, document.body.scrollHeight);
  return div;
}

async function boot() {
  try { await api("/api/wake", { method: "POST" }); } catch { /* keep polling */ }
  for (let i = 0; i < 180; i++) {
    let state = "waking";
    try { state = (await (await api("/api/status")).json()).state; } catch { /* still asleep */ }
    // once the API answers, the cluster is up
    setStep(state === "waking" ? "waking" : state);
    if (state === "ready") return startChat();
    await new Promise(r => setTimeout(r, 2000));
  }
  document.querySelector("#boot h2").textContent = "Couldn't get resources ready. Please retry.";
}

async function startChat() {
  document.getElementById("boot").hidden = true;
  document.getElementById("chat").hidden = false;
  const h = await (await api("/api/history")).json();
  document.getElementById(h.stored ? "saved" : "guest").style.display = "block";
  h.chats.forEach(c => { bubble("user", c.prompt); bubble("bot", c.reply); });
}

document.getElementById("composer").addEventListener("submit", async e => {
  e.preventDefault();
  const input = document.getElementById("msg");
  const send = document.getElementById("send");
  const text = input.value.trim();
  if (!text) return;
  input.value = "";
  send.disabled = true;
  bubble("user", text);
  const out = bubble("bot", "…");

  try {
    const res = await api("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message: text }),
    });
    if (!res.ok) {
      out.textContent = res.status === 429 ? "Slow down a little and try again." : "Something went wrong.";
      return;
    }
    out.textContent = "";
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let cut;
      while ((cut = buf.indexOf("\n\n")) >= 0) {
        const frame = buf.slice(0, cut);
        buf = buf.slice(cut + 2);
        const ev = (frame.match(/^event: (.*)$/m) || [])[1] || "message";
        const data = (frame.match(/^data: (.*)$/m) || [])[1];
        if (!data) continue;
        const d = JSON.parse(data);
        if (ev === "message" && d.token) { out.textContent += d.token; window.scrollTo(0, document.body.scrollHeight); }
        if (ev === "error") out.textContent = d.error;
        if (ev === "meta") {
          document.getElementById("guest").style.display = d.stored ? "none" : "block";
          document.getElementById("saved").style.display = d.stored ? "block" : "none";
        }
      }
    }
  } catch {
    out.textContent = "Connection lost. Try again.";
  } finally {
    send.disabled = false;
    input.focus();
  }
});

boot();
