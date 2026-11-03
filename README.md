# QwenOps — local build (Docker → Kubernetes)

A small Qwen chatbot (Ollama, `qwen2.5:0.5b`) with a FastAPI backend, a static UI, Postgres history
(first 50 users, last 15 chats each), deployed to **k3s** in **dev / qa / prod** namespaces with
security controls on by default. Sized for **8 GB RAM / 8 cores**.

```
browser ──► Traefik ingress (k3s) ──► ui (nginx)            namespace chatbot-<env>
                              └─/api─► chat-api (FastAPI) ──► ollama   (namespace ai)
                                                         ├──► postgres (namespace data, db per env)
                                                         └──► prometheus (namespace monitoring, Pulse page)
```

## What's in here

| Path | What |
|---|---|
| `app-chat/` | FastAPI chat API, DB schema with retention triggers, tests, Dockerfile |
| `app-ui/` | Chat page, CI/CD factory page (demo), "Be a Dev" colour page, **Pulse** live dashboard, nginx image |
| `compose.yaml` | Quick test with Docker before Kubernetes |
| `monitoring/` | Prometheus config for the Compose test |
| `k8s/platform/` | Namespaces (PSA restricted), quotas, default-deny network policies, Ollama, Postgres, Prometheus |
| `helm/chatbot/` | App chart + `values-dev/qa/prod.yaml` |
| `scripts/` | Numbered setup scripts, tests, verification |

## Prerequisites (on the Ubuntu Server machine)

- Ubuntu Server 22.04/24.04, 8 GB RAM, ~20 GB free disk
- Docker Engine: `curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker $USER` (log out/in)
- `git`, `make`, `openssl`, `curl`
- Optional but recommended: [Trivy](https://trivy.dev) and [hadolint](https://github.com/hadolint/hadolint) — the build script uses them if present

## Step 1 — Run the tests

```bash
make test        # ruff + 3 pytest cases against a throwaway Postgres
```
Proves the database refuses the 51st user and keeps only each user's newest 15 chats.

## Step 2 — Quick check with Docker Compose (optional, ~5 min)

```bash
cp .env.example .env          # then replace both secrets:  openssl rand -hex 32
make compose                  # first run downloads the model (~400 MB)
```
Open http://localhost:8080. Stop with Ctrl+C, then `docker compose down` before Step 3
(both use RAM; don't run them together on 8 GB).

## Step 3 — Install k3s (once)

```bash
make k3s          # hardened k3s + Helm: secrets encryption, audit log, kernel protections, 4 GB swap
make apparmor     # pods' AppArmor profile (also run by make k3s; re-run after an OS upgrade)
make registry     # private registry on localhost:5000
```

## Step 4 — Platform: namespaces, guardrails, Ollama, Postgres

```bash
make platform     # also generates random secrets straight into the cluster (never on disk)
```
First run pulls the model into a volume; later restarts reuse it.

## Step 5 — Build and deploy

```bash
git init && git add -A && git commit -m "feat: initial local stack"   # tag = git SHA
make build        # build → (hadolint, trivy) → push, tagged with the commit SHA
make deploy-dev
make deploy-qa    # promotes the SAME image tag
make deploy-prod  # asks for confirmation
```

Add hostnames (on the server; from another PC use the server's LAN IP instead of 127.0.0.1):
```bash
echo "127.0.0.1 chatbot.local dev.chatbot.local qa.chatbot.local" | sudo tee -a /etc/hosts
```
Open http://dev.chatbot.local, http://qa.chatbot.local, http://chatbot.local — each shows its
environment badge and its own theme colour.

## Step 6 — Verify it works *and* that the security controls block things

```bash
make verify ENV=dev
```
Checks: UI/API/model up · metrics not public · CSP headers · bad colour rejected · Pulse page has live
data and rejects unknown ranges · privileged pod rejected by Pod Security Admission · a random pod can't
reach Postgres, Ollama, Prometheus or the internet · no service-account token in the API pod.

## Pulse — the live dashboard (`/pulse/`)

Live view of the environment you're on, refreshed every 5 s (15 min / 1 h / 6 h ranges):

- **Traffic:** API requests/s, share of server errors, chat reply time (p50/p95), time to first word, model tokens/s, replies streaming right now
- **Resources:** host CPU and memory with OK / High / Critical levels, CPU and memory per workload (this env's app, model, database, monitoring), a per-pod table
- **App state:** API pods up, model ready/loading, users with saved history (of 50)

How it's wired, and why it's safe to show publicly:
- Prometheus runs privately in the `monitoring` namespace (PSA restricted, default-deny, 384 MB limit, 24 h of data).
  It scrapes chat-api's metrics port and the kubelet's resource metrics with read-only RBAC (no `nodes/proxy`).
- The browser calls `/api/pulse?range=15m|1h|6h` only. chat-api runs a **fixed** set of queries scoped to its own
  environment, caches the result for 4 s (many viewers = one set of queries) and rate-limits each IP.
  No PromQL ever comes from the browser, and Prometheus is not on the ingress.
- In Docker Compose, Pulse shows traffic and chat numbers; CPU/memory need Kubernetes (the kubelet).

## Useful commands

```bash
make logs ENV=prod                       # tail API logs
kubectl get pods -A                      # everything
kubectl top pods -A                      # RAM/CPU per pod (metrics-server is built into k3s)
kubectl -n chatbot-dev describe quota    # how full each environment is
helm history chatbot-prod -n chatbot-prod && helm rollback chatbot-prod <rev> -n chatbot-prod
```

## Memory budget (8 GB host)

| Piece | Limit |
|---|---|
| OS + k3s + Traefik + reserved | ~2.3 GB |
| Ollama (shared, `ai`) | 2 GB |
| Postgres (shared, `data`) | 384 MB |
| Prometheus (shared, `monitoring`) | 384 MB |
| prod (2–3 API + 2 UI) | 1.5 GB quota |
| dev, qa | 768 MB quota each |

If RAM is tight: `kubectl -n chatbot-qa scale deploy --all --replicas=0` when you're not testing qa.
Jenkins (Phase 4) needs ~2 GB, so scale qa to 0 while building.

## Security controls included

- **Images:** multi-stage, non-root (uid 10001 / 101), no shell tools added, OCI labels with Git SHA, `.dockerignore`, Trivy + hadolint in the build script. Pin digests with `./scripts/pin-digests.sh`.
- **Pods:** PSA `restricted` on every namespace; `runAsNonRoot`, read-only root FS, all capabilities dropped, seccomp `RuntimeDefault`, no privilege escalation, no SA token.
- **Network:** default-deny in/out per namespace; only Traefik → ui/api; only chat-api → Ollama/Postgres; Ollama may only reach public HTTPS (model download).
- **Resources:** requests/limits everywhere, ResourceQuota + LimitRange per namespace, PDB + HPA in prod.
- **Data:** a separate Postgres database and login per environment; retention enforced by triggers.
- **Secrets:** random, generated into the cluster, never in Git or on disk; k3s encrypts them at rest.
- **App:** input validation, per-user/IP rate limits, signed HttpOnly cookies, CSP and other headers, metrics on a non-public port, JSON logs without message contents.

## Notes / next phases

- **Ollama version:** pinned to `ollama/ollama:0.30.10`. Check https://github.com/ollama/ollama/releases and bump it in `k8s/platform/30-ollama.yaml` and `.env`.
- **TLS:** HTTP locally for now. Phase 3.4 adds cert-manager; then set `cookieSecure: true`.
- **Pipeline page** runs a demo build; Phase 8 connects it to Jenkins. **Colour page** validates and rate-limits now; Phase 8 makes it trigger the `theme-deploy` job.
- **Wake-on-LAN:** `/api/wake` is a stub locally; Phase 7 sends it to SQS for the Raspberry Pi relay.
