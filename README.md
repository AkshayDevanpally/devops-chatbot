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
| `app-ui/` | Chat page, CI/CD factory page (demo), "Be a Dev" colour page, **Pulse** live dashboard, **Architecture** diagrams (`/architecture/`), nginx image |
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

Add hostnames on the server itself:
```bash
echo "127.0.0.1 chatbot.local dev.chatbot.local qa.chatbot.local" | sudo tee -a /etc/hosts
```
Other devices on the home network find the names through the Raspberry Pi gateway (see *Sleep and wake*),
which announces them over mDNS. Don't add hosts-file entries pointing at the server on other PCs: they go around
the Pi, so a sleeping server never wakes. If a device can't use mDNS, point the names at the Pi (192.168.1.104).
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
   Other devices find `jenkins.chatbot.local` through the Pi gateway (or a hosts entry pointing at the Pi).

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

## Overload protection

Each chat-api pod streams one reply at a time from the model and keeps a short line (dev and qa 2, prod 4,
waiting up to 30 s). Waiting people see "you're in line"; when the line is full they get "Busy right now… try
again" at once (HTTP 503) instead of a two-minute hang. Settings: `api.chat` in the Helm values. Priority classes
put Postgres, Ollama and Prometheus first, prod second, and dev, qa and Jenkins last when memory runs short.
The `ChatsTurnedAway` alert fires if more than 10% of prod chats get "busy". Details: update 8 in `docs/updates.txt`.

## Sleep and wake (Phase 7)

The server sleeps when nobody uses it and wakes when someone opens the site. A Raspberry Pi (always on, Wi-Fi,
192.168.1.104) stands in front of it: it announces `chatbot.local` & co. on the network and passes everything
through to the server; if the server is asleep it shows "Waking it up…", sends the Wake-on-LAN magic packet and
reloads into the site once the server answers (about a minute).

```bash
make sleep-setup           # once, sudo: Wake-on-LAN on; sleep after 30 idle min; wake 07:50 IST for backups
make sleep-status          # would it sleep now, and if not, why
make sleep-now MINUTES=2   # sudo: sleep now and wake by itself after 2 min (without MINUTES: 07:50 IST or a visit)
make stay-awake            # never sleep until: make allow-sleep
make wol-test              # sudo: test each link (card setting, Wi-Fi -> cable delivery, a real wake by the Pi)
make alert-test            # sudo: sleep 5 min WITHOUT telling the Pi; the phone gets "server down", then "back"

make pi-gateway            # set up / update the Pi (PI=user@ip, default rasppi@192.168.1.104; Pi's sudo password)
make pi-test               # 11 checks through the Pi
make pi-simulate           # pretend the server sleeps: waking page, magic packet (Pi's sudo password)
make pi-status             # Pi services, the waker, and what the watcher sees
make pi-quiet MINUTES=30   # planned reboot / BIOS work: no "server down" alert from the Pi meanwhile
make lan-share-ca          # sudo: serve the home CA for 10 min, to install on a phone or laptop
```

- **Idle** means 30 minutes with no app traffic (chats, Pulse, any `/api` call), no Jenkins build, no backup job, no
  AWS burst node, no SSH session (VS Code Remote counts, so it never sleeps under you) and no stay-awake switch.
  It stays awake 07:45–10:00 IST for the backup, restore test and off-site copy (times in `/etc/qwenops-sleep.conf`).
- Before sleeping it sends a quiet ntfy note and tells the Pi (with a token from secret `pi-gateway`). A Wake-on-LAN
  phone app also works: MAC `f8:bc:12:89:34:5f`, broadcast `192.168.1.255`, port 9.
- **Server-down alerts from the Pi:** the Pi checks the server every 30 s and sends urgent ntfy alerts for
  "Server is down (not asleep)" (3 min without an answer and no announced sleep), "didn't wake on schedule"
  (10 min after the planned wake), "didn't wake after a visit" (5 min after the wake packet), then "Server is back".
  Run `make pi-quiet` before planned reboots.
- **BIOS (Dell OptiPlex 3020, F2):** Wake on LAN = LAN Only, Deep Sleep Control = Disabled, Block Sleep off,
  Auto On Time off; AC Recovery = Last Power State is a good idea.
- **Needs:** fixed addresses for the server and the Pi (DHCP reservations; re-run `make pi-gateway` if they change),
  and clients that resolve `.local` names (iPhone, Mac, Windows 10/11, Android 12+) and trust the home CA.
- **While asleep nothing runs:** no alerts, no Jenkins builds (they run once it's awake). After waking, k3s needs
  1–2 minutes before the site answers.

## Alerts to your phone (ntfy)

```bash
make alerts          # install/update: Alertmanager, ntfy-bridge and the alert rules
make alerts-topic    # your private ntfy topic + how to subscribe (NEW=1 makes a new one)
make alerts-test     # send a test alert through the whole chain
make alerts-status   # rules loaded, alerts firing now, last notifications sent
```

Prometheus checks 11 rules (`alerts.yml` in `k8s/platform/50-prometheus.yaml`) and sends what fires to
Alertmanager, which groups alerts, reminds every 4 h (critical: every hour) and sends "Resolved" when they clear.
A small `ntfy-bridge` turns them into readable phone notifications on ntfy.sh (`k8s/platform/55-alerting.yaml`).

- **Critical:** home server memory > 90%, no prod chat-api up, > 5% of prod chats failing, > 5% of prod requests 5xx.
- **Warning:** burst recommended (prod at 3/3 home pods and first word > 15 s), model queue forming, CPU > 90% for
  15 min, a backup/off-site copy/restore test failed or overdue, backup-ops down, AWS burst node up > 4 h.
- The topic name is the only protection on ntfy.sh: keep it private (it lives in secret `ntfy`).
- **If the whole server is down,** these alerts can't run; the Raspberry Pi watches it instead and alerts
  "Server is down (not asleep)" (see *Sleep and wake*).

## Backups (Postgres)

```bash
make backups          # install/update: nightly 02:30 UTC, off-site every 3 days 04:15 UTC, restore test Sundays 03:30
make backup-offsite-setup   # once: S3 bucket (terraform/backups) + write-only key into the cluster
make backup-offsite-now     # copy the newest backup to S3 right away
make backup-admin-password  # password for "Back up now" on the Pulse page
make backup-now       # take one right away
make backup-status    # what's on the server, last runs
make backup-test      # restore the newest backup into a throwaway Postgres and check it
make backup-download  # copy the newest backup to ./backups (git-ignored; STAMP=... for another)
make db-restore ENV=dev STAMP=2026-11-05T1525Z   # replace one env's database (asks to confirm)
```

- **What:** one `pg_dump` per environment database (`chat_dev`, `chat_qa`, `chat_prod`) plus the roles, with a
  SHA-256 checksum file. Kept **14 days** on the `postgres-backups` volume in the `data` namespace. Each backup
  is written to a hidden folder and renamed only when complete; old ones are pruned only after a good backup.
- **Restore test:** every Sunday a job restores the newest backup into a private Postgres inside its own pod
  (no network, no credentials) and checks each database's tables, retention triggers and row counts.
- **Restoring for real:** `make db-restore` first takes a fresh safety backup, stops that environment's chat-api,
  restores in one transaction, then starts chat-api again. For prod you type `prod` to confirm.
- **Off-site:** every 3 days the newest backup is copied to a private, encrypted S3 bucket (kept 30 days). The
  upload key can only add files: it can't read or delete earlier copies.
- **Pulse page:** a Backups panel shows the last and next runs, each run's log (open it), and a **Back up now**
  button (admin password) that runs a backup and then the off-site copy. chat-api has no Kubernetes access; a
  small `backup-ops` service in `data` does the work (`k8s/platform/65-backup-ops.yaml`).
- The job runs with the same restrictions as every pod (non-root, read-only filesystem, AppArmor) and may reach
  only Postgres. The backup files hold chat data and password hashes; keep downloaded copies private.

## AWS: tunnel, burst compute and cost guardrails (Phases 5–6)

AWS is used only when the home server needs more capacity, and everything in it is destroyed afterwards,
except the cost guardrails (which cost nothing). Terraform and the AWS CLI use the profile `chatbot`
(region `ap-south-1`). Steps that need root print a `sudo` line to run, unless sudo still remembers your password.
Full details and test results: `docs/updates.txt`.

**Postgres TLS (once, home side):**

```bash
make db-tls             # certificate from the local CA, TLS 1.3, pg_hba.conf rules for the tunnel; 9 checks
```

**Tunnel test (Phase 5).** A tiny AWS node; the home server dials out to it over WireGuard (`wg0`):

```bash
make tunnel-up          # create the AWS node + home wg0 config (run the sudo lines it prints)
make tunnel-test        # 7 checks from AWS: TLS verify-full, refused logins, tunnel address kept
make tunnel-status      # AWS node and wg0 state
make tunnel-down        # wg0 down + destroy everything in AWS
```

**Burst compute (Phase 6).** One Spot machine (4 vCPU amd64, picked by an EC2 Fleet from 10 types in 3 zones,
$0.05–0.08/h) joins k3s and runs extra prod chat-api pods with their own Ollama. It destroys itself after 30 idle
minutes or 6 hours:

```bash
make burst-prepare      # once, sudo: firewall rules on wg0 for the burst node
make burst-up           # create the node + home wg0; if it prints sudo lines, run them, then: make burst-ready
make burst-test         # node, pods, Postgres over TLS, a real model answer, Capacity page
make burst-status       # AWS node, wg0 and the pods on the burst node
make burst-down         # burst pods off, node removed, wg0 down, destroy everything in AWS
```

Run `make burst-down` also after the node ended on its own (idle, max lifetime or Spot reclaim), to tidy up.
The tunnel test and burst compute share the tunnel addresses, so only one can be up at a time.

**Cost guardrails (stay up, $0).** A $10/month budget: emails at 50%, 80% and when forecast to pass $10; at
100% the Terraform user loses the right to create machines and a kill switch terminates every EC2 instance in
every region. Billing data lags several hours, so it is a backstop, not an exact cap.

```bash
make guardrails-up      # create/update (alert email in terraform/guardrails/terraform.tfvars, gitignored)
make guardrails-test    # kill switch dry run: what it would remove right now
make guardrails-status  # spend this month, cut-off armed or fired, deny policy attached?
make guardrails-reset   # after a cut-off: give the Terraform user its create rights back
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
  - **Backups** are now our job (RDS did them before): nightly on the server since 2026-11-05 (see *Backups* below).
    Still open: a copy kept off the server.
- **AWS cost rule (applies to Phases 5–9):** AWS is used only when the home server needs extra capacity,
  and is provisioned with Terraform. When that capacity is no longer needed, **every AWS resource is destroyed**.
  Nothing in AWS holds data, so a single Terraform stack is enough and `terraform destroy` is always safe.
  Phase 5 is now the tunnel above (WireGuard config, Postgres TLS, the NetworkPolicy rule); Phase 6 the burst compute.
  - **Phase 5 home side: done (2026-11-09), `make db-tls`.** Postgres has a certificate from the local CA
    (`k8s/tunnel/10-postgres-tls.yaml`, 90 days, renewed and reloaded automatically) and requires TLS 1.3 when
    TLS is used; the apps already connect over TLS. `pg_hba.conf` is now a ConfigMap: the tunnel subnet
    `10.200.0.0/24` gets TLS + SCRAM, app roles only, each to its own database; the pod network keeps SCRAM;
    everything else is rejected. Service `postgres-tunnel` answers on the tunnel address `10.200.0.1:5432`.
    AWS clients use `sslmode=verify-full sslrootcert=certs/postgres-ca.crt`.
  - **Phase 5 tunnel test: passed (2026-11-09), `make tunnel-up` / `tunnel-test` / `tunnel-down`.** Terraform in
    `terraform/tunnel/` makes a t4g.nano WireGuard endpoint (own VPC, WireGuard from the home IP only, no SSH, SSM
    for commands); the home server dials out with `wg0` (sudo steps are printed). 7 of 7 checks passed from AWS.
    Details: `docs/updates.txt`.

- **Ollama version:** pinned to `ollama/ollama:0.30.10`. Check https://github.com/ollama/ollama/releases and bump it in `k8s/platform/30-ollama.yaml` and `.env`.
- **TLS:** done in Phase 3.4 with a local CA. HSTS is 1 day (`tls.hstsSeconds`); raise it once certificates come from a public CA (e.g. Let's Encrypt in AWS).
- **Pipeline page** runs a demo build; its stations match the Jenkinsfile stages, and Phase 8 connects it to live Jenkins events. Image signing (cosign + an admission check) is a follow-up to the SBOM step. **Colour page** validates and rate-limits now; Phase 8 makes it trigger the `theme-deploy` job.
- **Wake-on-LAN (Phase 7, done):** the Raspberry Pi gateway answers `/api/wake` and `/api/status` while the server
  sleeps and sends the magic packet on the home network; no AWS (SQS) part was needed. See *Sleep and wake*.
