// Stations map 1:1 to Jenkinsfile stages. In Phase 8 `feed()` is replaced by a WebSocket
// from the pipeline-events service; the rendering code stays the same.
const STAGES = [
  { id: "checkout", name: "Checkout", icon: "📦", log: ["Cloning repo…", "HEAD is now at 3f2a9c1"] },
  { id: "build", name: "Build", icon: "🏭", log: ["docker build --target runtime .", "Successfully built chat-api:3f2a9c1"] },
  { id: "test", name: "Test", icon: "🔍", log: ["pytest -q", "3 passed in 1.42s", "Quality gate: PASSED"] },
  { id: "scan", name: "Security scan", icon: "🩻", log: ["trivy image chat-api:3f2a9c1", "HIGH: 0  CRITICAL: 0"] },
  { id: "sign", name: "Sign & box", icon: "🎁", log: ["trivy image --format spdx-json -> sbom/chat-api-3f2a9c1.spdx.json", "pushed localhost:5000/chat-api:3f2a9c1"] },
  { id: "dev", name: "Deploy dev", icon: "🧪", log: ["helm upgrade --install chatbot-dev --atomic", "rollout complete"] },
  { id: "qa", name: "Deploy qa", icon: "✅", log: ["helm upgrade --install chatbot-qa --atomic", "make verify ENV=qa: passed 22, failed 0"] },
  { id: "prod", name: "Ship to prod", icon: "🚚", log: ["Approved by owner", "helm upgrade --install chatbot-prod --atomic", "live"] },
];

const logs = Object.fromEntries(STAGES.map(s => [s.id, []]));
let openStage = null;
const factory = document.getElementById("factory");

STAGES.forEach(s => {
  const el = document.createElement("div");
  el.className = "station";
  el.id = `st-${s.id}`;
  el.innerHTML = `<div class="icon">${s.icon}</div><div class="name"></div><div class="st">pending</div>`;
  el.querySelector(".name").textContent = s.name;
  el.addEventListener("click", () => openLogs(s));
  factory.appendChild(el);
});

function setStatus(id, status) {
  const el = document.getElementById(`st-${id}`);
  el.className = `station ${status}`;
  el.querySelector(".st").textContent = status;
  if (status === "running") {
    const idx = STAGES.findIndex(s => s.id === id);
    document.getElementById("box").style.left = `calc(${(idx / (STAGES.length - 1)) * 100}% - ${idx ? 26 : 0}px)`;
  }
}

function appendLog(id, line) {
  logs[id].push(`[${new Date().toLocaleTimeString()}] ${line}`);
  if (openStage === id) render();
}

function openLogs(s) {
  openStage = s.id;
  document.getElementById("drawer").style.display = "block";
  document.getElementById("drawer-title").textContent = `Logs: ${s.name}`;
  render();
}

function render() {
  const pre = document.getElementById("drawer-log");
  pre.textContent = logs[openStage].join("\n") || "(no output yet)";
  pre.scrollTop = pre.scrollHeight;
}

document.getElementById("drawer-close").onclick = () => {
  openStage = null;
  document.getElementById("drawer").style.display = "none";
};

async function feed() {
  const btn = document.getElementById("run");
  btn.disabled = true;
  STAGES.forEach(s => { logs[s.id] = []; setStatus(s.id, "pending"); });
  for (const s of STAGES) {
    setStatus(s.id, "running");
    for (const line of s.log) {
      await new Promise(r => setTimeout(r, 500 + Math.random() * 600));
      appendLog(s.id, line);
    }
    setStatus(s.id, "passed");
  }
  btn.disabled = false;
}

document.getElementById("run").onclick = feed;
