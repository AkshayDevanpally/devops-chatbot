# QwenOps — local build (Docker → Kubernetes)

A small Qwen chatbot (Ollama, `qwen2.5:0.5b`) with a FastAPI backend, a static UI, Postgres history
(first 50 users, last 15 chats each), deployed to **k3s** in **dev / qa / prod** namespaces with
security controls on by default. Sized for **16 GB RAM / 4 cores**.

```
browser ─HTTPS─► Traefik ingress (k3s, cert from cert-manager) ──► ui (nginx)            namespace chatbot-<env>
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
| `Jenkinsfile` | CI/CD pipeline: checkout → build → test → scan → SBOM + push → dev → qa → approved prod |
| `ci/jenkins/`, `k8s/ci/` | Jenkins controller image (plugins baked in) and its k3s manifests + deployer RBAC |
| `k8s/tls/` | cert-manager namespace + policies, local CA, Traefik HTTP→HTTPS redirect |
| `k8s/platform/` | Namespaces (PSA restricted), quotas, default-deny network policies, Ollama, Postgres, Prometheus |
| `helm/chatbot/` | App chart + `values-dev/qa/prod.yaml` |
| `scripts/` | Numbered setup scripts, tests, verification |

## Prerequisites (on the Ubuntu Server machine)

- Ubuntu Server 22.04 or newer, 16 GB RAM, 4 cores, ~20 GB free disk
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
(both run their own Ollama and compete for the 4 CPU cores).

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

## Step 4b — HTTPS (cert-manager + local CA)

```bash
make tls          # cert-manager, a private CA, HTTP→HTTPS redirect; writes certs/chatbot-local-ca.crt
make trust-ca     # trust that CA on this machine (sudo)
```
The CA's private key stays in the cluster (encrypted at rest); only the public certificate is exported.
Each environment's Ingress gets its own certificate from the CA when it's deployed (Step 5); cert-manager
renews them automatically.

Trust the CA on other devices (copy `certs/chatbot-local-ca.crt` over):
- **Firefox:** Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import
- **Chrome/Edge on Windows:** double-click the file → Install → Local Machine → "Trusted Root Certification Authorities"
- **macOS:** open it in Keychain Access → System → set "Always Trust"
- **Android/iOS:** install as a CA certificate in security settings

Only import a CA you created yourself, and delete `certs/` if the machine is shared.

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
Open https://dev.chatbot.local, https://qa.chatbot.local, https://chatbot.local — each shows its
environment badge and its own theme colour.

## Step 6 — Verify it works *and* that the security controls block things

```bash
make verify ENV=dev
```
Checks: UI/API/model up · certificate issued by the local CA · HTTP redirects to HTTPS · HSTS · Secure cookie · TLS 1.1 refused · metrics not public · CSP headers · bad colour rejected · Pulse page has live
data and rejects unknown ranges · privileged pod rejected by Pod Security Admission · a random pod can't
reach Postgres, Ollama, Prometheus or the internet · no service-account token in the API pod.

## Step 7 — CI/CD with Jenkins (Phase 4)

```
GitHub (private) ◄─poll every 2 min── Jenkins controller (k3s, namespace ci, https://jenkins.chatbot.local)
                                            │ WebSocket over the HTTPS ingress
                                            ▼
                         host agent (systemd, user jenkins-agent) ── docker / trivy / helm
                                            │ kubeconfig limited to chatbot-dev/qa/prod
                                            ▼
                               dev ──► qa ──► (approval) ──► prod
```

1. **Push the repo to GitHub** (private). Create an empty private repo on github.com, then:
   ```bash
   git remote add origin git@github.com:<you>/<repo>.git
   git push -u origin master
   ```
2. **Start Jenkins**: `make jenkins` (reads the `origin` remote). It builds and scans the controller
   image, generates the admin password and a deploy key into the cluster, and prints the public key.
3. **Add the deploy key** on GitHub: repo → Settings → Deploy keys → Add, **read-only**.
4. **Connect the build agent**: `make jenkins-agent` (sudo). Installs Java, creates the `jenkins-agent`
   system user, a deploy-only kubeconfig, and a hardened systemd service.
5. Open https://jenkins.chatbot.local (user `admin`, password from `make jenkins-password`).
   Add `jenkins.chatbot.local` to the hosts file of the PC you open it from.

Every push to `master` runs the pipeline within ~2 minutes: the same SHA-tagged image goes to dev and qa
(each verified with `make verify`), then waits up to a day for someone to click **Ship it** for prod.
The SBOM for each image is attached to the build.

- **Automatic rollback:** every deploy goes through `scripts/promote.sh` (deploy → verify). If verification
  fails, that environment is rolled back to the release it had before and the build fails. A red build
  never means a broken release is live.
- **Builds don't block each other:** a build waiting for prod approval doesn't hold up newer pushes. Deploys
  stay in commit order, and approving a newer build cancels older ones still waiting.
- `make verify` takes about 30 s (all network checks run from one probe pod).

How it's kept safe:
- **Controller** (k3s): PSA restricted, read-only root FS, no Kubernetes API token, 0 executors, default-deny
  network (in: Traefik only; out: public SSH/HTTPS only), plugins baked into a scanned image, everything
  configured as code (`k8s/ci/20-jenkins.yaml`); sign-up and anonymous access off.
- **GitHub access**: read-only deploy key for this one repo; GitHub's SSH host key is pinned.
- **Agent** (host): dedicated no-login user; systemd sandbox (read-only OS, no `/home`, no privilege gain).
  It is in the `docker` group, which is root-equivalent on this host, so the job only builds this repo's
  own `master` branch. Never point it at untrusted code or pull requests from forks.
- **Deploys**: ServiceAccount `ci/jenkins-deployer` can only manage the chart's resources in the three app
  namespaces (`k8s/ci/10-deployer-rbac.yaml`); prod also needs a human approval.

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

## Capacity (`/capacity/`) and Error Journal (`/journal/`)

**Capacity** splits the screen in two, refreshed every 10 s:
- 🏠 **Local hardware**: host CPU and memory (with OK / High / Critical), pods, prod API pods against the
  local ceiling where AWS burst starts, a one-hour CPU/memory chart, and memory per namespace.
- ☁️ **AWS**: burst compute (Phase 6). With nothing running it says *Nothing running · $0/h*, which is
  the normal state under the AWS cost rule. The database is not in AWS; it appears on the local side (`data`).

It uses the same safety model as Pulse: the browser calls `/api/capacity` (no parameters); chat-api runs fixed
Prometheus queries. Local and AWS numbers are kept apart by one label: **anything scraped from AWS must carry
`cloud="aws"`** (add it in the scrape config when Phase 6 brings AWS metrics in). Local queries exclude it.

**Error Journal** shows every incident written up in `docs/` as a self-scrolling journal: hover (or focus)
to pause and scroll by hand, move away to resume; speed and status filters; reduced-motion users get no animation.
- Built at image build time by `app-ui/journal/build_journal.py` (standard library only), which reads
  `.docx`, `.md` and `.txt`. Each file is a chapter; each section at its most common heading level is an entry,
  tagged with an emoji and a status (taken from the doc's own summary table when it has a `#` / `Status` table).
- **New or edited docs appear after the next pipeline run**: push to `master` → Jenkins builds the UI image
  (which runs the generator) → deploy. The open page also re-checks every 5 minutes.
- The site may be public, so the generator **redacts** private IPs, SSH keys, long hex strings, password
  assignments and emails. Still, never put secrets in `docs/`.

## Useful commands

```bash
make logs ENV=prod                       # tail API logs
kubectl get pods -A                      # everything
kubectl top pods -A                      # RAM/CPU per pod (metrics-server is built into k3s)
kubectl -n chatbot-dev describe quota    # how full each environment is
helm history chatbot-prod -n chatbot-prod && helm rollback chatbot-prod <rev> -n chatbot-prod
```

## Resource budget (16 GB / 4-core host)

CPU is the tight resource here, not memory: the model generates on CPU, so Ollama may use 3 of the
4 cores. Memory limits are sized so everything, including Jenkins and its builds, fits.

| Piece | Memory limit |
|---|---|
| OS + k3s + Traefik + reserved | ~2.5 GB |
| Ollama (shared, `ai`) | 4 GB (0.5b uses ~1 GB; room for `qwen2.5:1.5b` or `3b`) |
| Postgres (shared, `data`) | 768 MB (`shared_buffers=256MB`) |
| Prometheus (shared, `monitoring`) | 384 MB |
| cert-manager (3 pods) | 240 MB |
| Jenkins controller (`ci`) | 1.5 GB (builds run on the host, outside these limits) |
| prod (2–3 API + 2 UI) | 1.5 GB quota |
| dev, qa | 768 MB quota each |
| **Total** | **~12.5 GB**, leaving ~2.5 GB for builds on the host and page cache |

To try a bigger model: change `MODEL` in `k8s/platform/30-ollama.yaml`, `model` in
`helm/chatbot/values.yaml` (and `.env` for Compose), then `make platform` and redeploy each env. Expect slower replies on 4 cores (1.5b ≈ 3× slower than 0.5b).

## Security controls included

- **Images:** multi-stage, non-root (uid 10001 / 101), no shell tools added, OCI labels with Git SHA, `.dockerignore`, Trivy + hadolint in the build script. Pin digests with `./scripts/pin-digests.sh`.
- **Pods:** PSA `restricted` on every namespace; `runAsNonRoot`, read-only root FS, all capabilities dropped, seccomp `RuntimeDefault`, no privilege escalation, no SA token.
- **Network:** default-deny in/out per namespace; only Traefik → ui/api; only chat-api → Ollama/Postgres; Ollama may only reach public HTTPS (model download). Known limit: k3s's built-in policy engine applies egress rules a few seconds after a pod starts, so a brand-new pod briefly has open egress (the verify probe waits 10 s for this; Cilium or Calico would close the gap).
- **Resources:** requests/limits everywhere, ResourceQuota + LimitRange per namespace, PDB + HPA in prod.
- **Data:** a separate Postgres database and login per environment; retention enforced by triggers.
- **Secrets:** random, generated into the cluster, never in Git or on disk; k3s encrypts them at rest.
- **TLS:** cert-manager with a private CA (ECDSA P-256), HTTP→HTTPS redirect, HSTS, `Secure` cookies; cert-manager runs in its own PSA-restricted, default-deny namespace with no internet access.
- **App:** input validation, per-user/IP rate limits, signed HttpOnly cookies, CSP and other headers, metrics on a non-public port, JSON logs without message contents.

## Notes / next phases

- **Database stays at home (changed 2026-11-05, replaces the RDS plan):** there is no RDS. The one Postgres
  in `k8s/platform/40-postgres.yaml` serves dev, qa and prod, and AWS burst pods use it too. The link:
  - **WireGuard tunnel, dialled out from home.** The home server connects *to* the AWS burst node, so no router
    port forward is needed and a changed home IP doesn't matter. Postgres is never exposed to the internet.
  - Postgres accepts tunnel traffic only from the tunnel subnet, with TLS (certificate from the local CA,
    `sslmode=verify-full`) and SCRAM passwords; the `postgres-allow` NetworkPolicy gets a rule for that subnet only.
  - Every query from AWS crosses the internet (~20–60 ms). Fine for chat, which does a few queries per message.
  - If the home server is down, AWS pods can't reach data and fail their readiness check. That's accepted: the
    model and the rest of the platform live at home too.
  - **Backups** are now our job (RDS did them before): a nightly `pg_dump` per environment, with a copy kept off
    the server. To do before real users arrive.
- **AWS cost rule (applies to Phases 5–9):** AWS is used only when the home server needs extra capacity,
  and is provisioned with Terraform. When that capacity is no longer needed, **every AWS resource is destroyed**.
  Nothing in AWS holds data, so a single Terraform stack is enough and `terraform destroy` is always safe.
  Phase 5 is now the tunnel above (WireGuard config, Postgres TLS, the NetworkPolicy rule); Phase 6 the burst compute.

- **Ollama version:** pinned to `ollama/ollama:0.30.10`. Check https://github.com/ollama/ollama/releases and bump it in `k8s/platform/30-ollama.yaml` and `.env`.
- **TLS:** done in Phase 3.4 with a local CA. HSTS is 1 day (`tls.hstsSeconds`); raise it once certificates come from a public CA (e.g. Let's Encrypt in AWS).
- **Pipeline page** runs a demo build; its stations match the Jenkinsfile stages, and Phase 8 connects it to live Jenkins events. Image signing (cosign + an admission check) is a follow-up to the SBOM step. **Colour page** validates and rate-limits now; Phase 8 makes it trigger the `theme-deploy` job.
- **Wake-on-LAN:** `/api/wake` is a stub locally; Phase 7 sends it to SQS for the Raspberry Pi relay.
