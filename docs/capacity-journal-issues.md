# Capacity & Error Journal pages, pipeline hardening — issues log

Problems hit on 4–5 November 2026:
- Issues 1–8: adding the Capacity page (local hardware vs AWS) and the Error Journal page, found while testing on dev.
- Issue 9: the first pipeline run that shipped the pages to prod, which led to a fix for dropped requests during every deploy.
- Issues 10–13: pipeline hardening (automatic rollback, non-blocking approvals, faster verify) and the mistakes along the way.
- Issue 14: automatic Ubuntu updates restarting the build agent in the middle of build #6.
- Issue 15: build #7 stopped by a vulnerability published overnight in the chat-api base image.
- Issues 16–18: builds #8, #10 and #11 (5 November): a failed GitHub fetch, and the new Architecture page's
  check failing in dev, plus the mistakes made while fixing it. Build #12 then shipped to prod.
- Issue 19: setting up nightly Postgres backups (on the server, 14 days, weekly restore test).
- Issue 20 (9 November): Phase 5 home side, TLS for Postgres and the tunnel rules (see docs/updates.txt).
- Issue 21 (9 November): Phase 5 tunnel test against a small AWS node (see docs/updates.txt).
- Issue 22 (9 November): first `make burst-up` (Phase 6) stopped with exit code 141.
- Issues 23–25 (9 November): the next Phase 6 runs: a setting AWS refuses for Spot, AppArmor stopping `wg-quick`
  from starting docker, and the Spot machine taken back after 7 minutes.
- Issues 26–27 (9 November): three EC2 Fleet errors in a row, then a wrong check in `burst-test`. After that,
  Phase 6 passed 11 of 11 checks.
- Issues 28–30 (9 November): off-site backups and the Pulse backups panel.
- Issues 31–32 (9 November): phone alerts through ntfy.
- Issues 33–34 (9 November): overload protection and its load test.
- Issue 35 (9 November): the Pulse page doesn't open on a phone on the home Wi-Fi (open).

| # | Issue | Area | Status |
|---|---|---|---|
| 1 | Journal entries stayed invisible after load | Frontend | Fixed |
| 2 | Headless screenshots made working animations look broken | Testing | Explained |
| 3 | Prod API pods always showed "High" | Frontend | Fixed |
| 4 | Pinned chapter header was see-through on phones | Frontend | Fixed |
| 5 | `make verify` failed "API liveness" right after a deploy | Deploy | Fixed (see Issue 9) |
| 6 | New journal check failed: `grep -q` + `pipefail` | Testing | Fixed |
| 7 | Journal statuses and emojis guessed wrong | Generator | Fixed |
| 8 | hadolint flagged the named build context | Build | Fixed |
| 9 | Build #4 "Ship to prod" failed: requests dropped during every rollout | Deploy | Fixed |
| 10 | Mistake: a post-deploy failure was dismissed as a timing blip | Process | Fixed |
| 11 | A build waiting for prod approval blocked the next build | Pipeline | Fixed |
| 12 | Build #4 went red although prod was deployed, and nothing rolled back | Pipeline | Fixed |
| 13 | Milestones rejected by Jenkins: "Missing required parameter: ordinal" | Pipeline | Fixed |
| 14 | Build #6 tests failed: automatic OS updates restarted the build agent mid-build | Host OS | Fixed |
| 15 | Build #7 security scan failed: new CVE in apt inside the Python base image | Security / images | Fixed |
| 16 | Build #8 failed before any stage: Jenkins couldn't reach GitHub | Network | Passed on rerun (cause not confirmed) |
| 17 | Builds #10 and #11 failed "Architecture page served" in dev and rolled back | Testing / deploy | Fixed |
| 18 | Mistakes: a known issue repeated, a wrong first diagnosis, two deploys to dev at once | Process | Fixed |
| 19 | First backup job: "Connection refused" from Postgres | Backups / network | Fixed |
| 20 | Postgres TLS check: "Connection refused" from inside the Postgres pod | Testing / network | Fixed |
| 21 | Tunnel test: AWS node setup did not finish (dnf OOM-killed), then a false handshake failure | AWS / testing | Fixed |
| 22 | First `make burst-up` stopped with exit code 141 while making the join token | Scripts | Fixed |
| 23 | `burst-up`: AWS refused "terminate on shutdown" for a Spot instance | Terraform / AWS | Fixed |
| 24 | `burst-up`: AppArmor stopped `wg-quick` from starting the registry copy (exit 126) | Host OS / AppArmor | Fixed |
| 25 | Spot machine taken back after 7 minutes ("no Spot capacity"); 3 checks failed | AWS / Spot | Fixed (fleet over 10 types, 3 zones) |
| 26 | EC2 Fleet refused three times: "minimum target capacity" (one wrong guess on the way) | Terraform / AWS | Fixed |
| 27 | `burst-test` said "0 of 0" Postgres connections; the check compared addresses wrongly | Testing | Fixed |
| 28 | "Back up now" answered "no password set" and "accepted" in turns: the old backup-ops pod kept serving | Backups / Kubernetes | Fixed |
| 29 | Before S3 was set up, the off-site copy would hang 15 minutes on a missing secret | Backups | Fixed |
| 30 | Manual backups didn't count as the last good backup | Backups | Fixed |
| 31 | Mistakes while testing alerts: broken quoting twice, a lost test topic, my own tests used up the per-IP limit | Process / testing | Fixed |
| 32 | ChatApiDown showed "pending" right after Prometheus restarted | Alerts | False alarm |
| 33 | Load test: people about to be turned away first saw "you're in line" | App / overload | Fixed |
| 34 | Load retests misled: same `-dirty` image tag reused, and an old pod still serving | Process / testing | Fixed |
| 35 | Pulse page doesn't open on a phone on the home Wi-Fi | Network | Open (fix scripted, not applied) |

### Issue 1 — Journal entries stayed invisible after load

**Symptom:** the journal frame showed only faint, almost transparent cards.

**Cause:** cards start at `opacity: 0` and rise in when they enter the viewer. The "entered" signal came from an
`IntersectionObserver`, and when its callback didn't fire, the cards never became visible. Content that depends
on an animation firing is fragile.

**Fix:** the reveal now runs inside the auto-scroll loop and compares positions directly (`offsetTop` against the
viewer's bottom edge), so it works for auto-scroll, manual scroll and filters. Reduced-motion users get every card
visible immediately.

**Lesson:** never make content visibility depend on an animation event; the fallback state must be readable.

### Issue 2 — Headless screenshots made working animations look broken

**Symptom:** screenshots taken with Chrome's `--screenshot --virtual-time-budget` showed cards frozen mid-fade, and
the scroll position barely moved between a 3-second and a 30-second shot.

**Cause:** virtual time fast-forwards timers but does not run CSS transitions and animation frames like a real
browser, so the page looked broken when it wasn't.

**Fix:** tested with a real browser (Puppeteer, real time): auto-scroll moved 179 px in 5 s (36 px/s as designed),
hover paused it, the mouse wheel scrolled freely, leaving resumed from the new position, the Pause button and the
filters worked, and there were no console errors.

**Lesson:** use static screenshots for layout only; test behaviour in a real browser with real time.

```text
autoscroll: 27 -> 206 | pill: ▶ Auto-scrolling | revealed 4 / 43
hover: 217 -> 217 | pill: ⏸ Paused. Scroll freely; move the mouse away to resume
manual wheel while hovered: 217 -> 817
after leaving: 817 -> 889 | pill: ▶ Auto-scrolling
pause button: 890 -> 890 | pill: ⏸ Paused. Press Play to resume
console errors: none
```

### Issue 3 — Prod API pods always showed "High"

**Symptom:** the Capacity tile read "2 / 3 ! High" with a yellow bar.

**Cause:** the warning started one pod below the burst point, but prod's normal minimum is 2 pods, so the normal
state looked like a problem.

**Fix:** "High" only at the local ceiling (3 of 3), where extra load bursts to AWS. 2 / 3 now reads ✓ OK.

**Lesson:** set thresholds from the system's normal state, not from the maximum.

### Issue 4 — Pinned chapter header was see-through on phones

**Symptom:** on a 390 px screen the first card's emoji and FIXED stamp showed through the pinned chapter header.

**Cause:** the sticky header used a fading (partly transparent) background and the same stacking level as the
cards; on phones the header is taller, so more of the card slid underneath the transparent part.

**Fix:** solid background, a border and shadow, and a higher stacking level; the sticky offset matches the phone
padding.

**Lesson:** check sticky elements at phone width, where they grow taller.

### Issue 5 — `make verify` failed "API liveness" right after a deploy

**Symptom:**

```text
FAIL  API liveness
passed: 21   failed: 1
```

**Cause:** the check ran seconds after the rollout, while the old chat-api pod was still shutting down. Three
`/api/healthz` calls straight after returned 200, and a rerun passed 22/22.

**Status:** first explained as a one-off. It recurred in build #4 (Issue 9), which showed the real cause and
led to the fix.

### Issue 6 — New journal check failed: `grep -q` + `pipefail`

**Symptom:** `FAIL  Journal built from docs/`, although the same command passed by hand.

**Cause:** `scripts/07-verify.sh` uses `set -o pipefail`. `grep -q` exits at the first match and closes the pipe;
curl, still sending the rest of the large JSON, gets SIGPIPE (exit 23), so the pipeline counts as failed. The
Capacity check passed only because its response is small enough to fit in the pipe buffer.

**Fix:** `grep '"entries"' >/dev/null` reads the whole body. Verify: 24 passed, 0 failed.

**Lesson:** with `pipefail`, avoid early-exit readers (`grep -q`, `head`) after a producer that may still be writing.

### Issue 7 — Journal statuses and emojis guessed wrong

**Symptom:** first generator run: "localhost:8000 would not open" marked OPEN (the word "open" in the title);
Postgres CrashLoopBackOff shown with 🔒; a log line saying "success" turned an error into 🎉; the plain-text
summary table was misread as "Field: value" lines; two back-to-back Markdown tables merged into one.

**Fix:** statuses now come from each doc's own summary table (`#` and `Status` columns) when present; emojis
match the title first, then the body, and 🎉 only from titles; labels are limited to short names; tables end
explicitly.

**Lesson:** prefer structure the author already wrote (summary tables) over keyword guessing.

### Issue 8 — hadolint flagged the named build context

**Symptom:** `DL3022 warning: COPY --from should reference a previously defined FROM alias`.

**Cause:** the UI image reads `docs/` through a named build context (`--build-context docs=docs`), which hadolint
cannot see, so it looks like an unknown stage.

**Fix:** `# hadolint ignore=DL3022` on that one line, with a comment explaining why.

### Issue 9 — Build #4 "Ship to prod" failed: requests dropped during every rollout

**Symptom:** build #4 deployed to prod successfully (approved by admin), then `make verify` failed one check:

```text
[2026-11-04T08:42:40.952Z] Deployed 2c40759 to prod -> https://chatbot.local
[2026-11-04T08:42:41.619Z] PASS  API ready (db + model reachable)
[2026-11-04T08:42:44.926Z] FAIL  model is loaded
[2026-11-04T08:45:52.058Z] passed: 23   failed: 1
ERROR: script returned exit code 1
Finished: FAILURE
```

A minute later `/api/status` answered `ready` on prod and dev. The failed check took ~3 s: a timed-out request.

**Cause:** with Issue 5 ("API liveness", which never touches the model) the pattern was clear: requests through
Traefik to a **brand-new pod** fail for a few seconds. Kubernetes routes to a pod as soon as it reports ready, but
k3s's policy engine adds the new pod to the "Traefik may connect" rule a few seconds later. On the way out, Traefik
keeps routing to old pods for a moment after they start shutting down. So every deploy dropped real user requests,
not just test requests.

**Measured on dev** (UI and API requested ~5×/s during a rollout):

| Rollout | Requests | Failed |
|---|---|---|
| Before the fix | 580 | 5 (502 and timeouts) |
| Deploying the fix (old pods still without the shutdown pause) | 708 | 4 |
| Restart with the fix | 760 | 0 |
| Restart with the fix, again | 760 | 0 |

**Fix:**
- chat-api and ui: `readinessProbe.initialDelaySeconds: 10`, so traffic only arrives once the network rule exists;
  `lifecycle.preStop.sleep: 5s`, so Traefik stops routing to an old pod before it exits.
- `make verify` first waits (up to 60 s) for five good answers in a row, so it tests the app, not the rollout.

**Lesson:** a flaky check right after a deploy is often a real, user-facing gap. Measure it under load before
calling it a fluke.

### Issue 10 — Mistake: a post-deploy failure was dismissed as a timing blip

**What happened:** when `make verify` first failed "API liveness" right after a dev deploy (Issue 5), the next three
health calls returned 200 and a rerun passed, so it was written down as "the old pod was shutting down" and left
alone. The same gap then failed the prod verify in build #4 (Issue 9).

**Why it was wrong:** a failure that only happens right after a deploy is not random. It happens on every deploy;
the test just catches it some of the time. And "API liveness" never touches the model, so the old-pod explanation
didn't fully fit; that mismatch was the clue.

**Fix:** measured instead of guessing (requests during rollouts: 5/580 failed before, 0/760 twice after), fixed the
rollout itself (Issue 9), and upgraded Issue 5 from "explained" to "fixed".

**Lesson:** "it passed on rerun" is not an explanation. If a failure is tied to an event (a deploy, a restart),
reproduce it under load before closing it.

### Issue 11 — A build waiting for prod approval blocked the next build

**Symptom:** after pushing the new pages, no new build started. Build #3 (from the docs-only push) was still
waiting at "Ship to prod":

```text
#3 PAUSED_PENDING_INPUT [('Deploy dev', 'SUCCESS'), ('Deploy qa', 'SUCCESS'), ('Ship to prod', 'PAUSED_PENDING_INPUT')]
queue: []
```

**Cause:** the job allows one build at a time (`disableConcurrentBuilds`), and the approval waits up to a day.
Every push that isn't shipped to prod holds up all later pushes until someone approves or aborts it.

**Workaround:** build #3 was aborted by hand (prod untouched; build #4 contained the same commit and more) and a new
build was started.

**Fix (5 November 2026):** builds may now overlap. The approval holds no agent, each stage checks out its own
build's commit (so overlapping builds can't share files), and `milestone` steps keep deploys in commit order:
approving a newer build cancels older builds still waiting at "Ship to prod".

### Issue 12 — Build #4 went red although prod was deployed, and nothing rolled back

**What happened:** in "Ship to prod", `helm upgrade --atomic` succeeded, so prod was running the new release; then
`make verify` failed one check and the build was marked FAILURE. The build said "failed", but the change was
live, and it stayed live: verify runs after the deploy, outside Helm's `--atomic` rollback.

**Risk:** if a verify failure is real, a broken release stays in prod until someone notices the red build and
rolls back by hand (`helm rollback chatbot-prod <rev> -n chatbot-prod`).

**Fix (5 November 2026):** every deploy (dev, qa, prod) goes through `scripts/promote.sh`: deploy, verify, and
on failure roll back to the revision that was live before, then fail the build. Tested on dev with a simulated
verification failure:

```text
Deployed 5ef1e72 to dev -> https://dev.chatbot.local
FAIL  simulated verification failure
!! verification failed in dev: rolling back to revision 12
Rollback was a success! Happy Helming!
14      Thu Nov  5 06:00:20 2026  deployed  chatbot-0.1.0  0.1.0  Rollback to 12
!! dev is back on revision 12. 5ef1e72 was NOT kept. Fix the failure and push again.
promote exit code: 1
```

### Issue 13 — Milestones rejected by Jenkins: "Missing required parameter: ordinal"

**Symptom:** validating the new Jenkinsfile with Jenkins' own linter (`/pipeline-model-converter/validate`):

```text
WorkflowScript: 77: Missing required parameter: "ordinal" @ line 77, column 9.
           milestone(label: 'deploy-dev')
           ^
```

**Cause:** in scripted pipelines `milestone()` numbers itself; declarative pipelines require an explicit
`ordinal`.

**Fix:** ordinals 10, 20, 30, 40 (gaps leave room for new stages). The linter then reported
"Jenkinsfile successfully validated".

**Lesson:** validate a Jenkinsfile against the running Jenkins before pushing; a syntax error only shows up
as a failed build otherwise.

### Issue 14 — Build #6 tests failed: automatic OS updates restarted the build agent mid-build

**Symptom:** build #6's Test stage failed with three database errors:

```text
11:36:32  ERROR tests/test_retention.py::test_only_first_50_users_are_stored - psycopg....
11:36:32  ERROR tests/test_retention.py::test_only_last_15_chats_per_user_are_kept - ps...
11:36:32  ERROR tests/test_retention.py::test_migration_is_idempotent - psycopg.Operati...
11:36:32  8 passed, 3 errors in 0.75s
E           psycopg.OperationalError: [Errno -3] Temporary failure in name resolution
```

**Investigation:** the test failure was a symptom. Just before it, the build log said:

```text
06:06:06  host-agent seems to be removed or offline (ChannelClosedException ...)
06:06:32  host-agent is back online
```

The agent's systemd journal showed it was told to stop at 06:05:56, not that it crashed. At 06:05:33
Ubuntu's unattended-upgrades started (libpcre2-8-0, bind9 libraries); its `needrestart` step then restarted
every service using an old copy of an updated library at the same moment: journald, ssh, cron and
jenkins-agent.

**Cause:** stopping the agent interrupted `scripts/test.sh`, whose cleanup removed the throwaway Postgres
container while the test container kept running, so the database name no longer resolved.

**Fix:** `scripts/09a-jenkins-agent.sh` writes `/etc/needrestart/conf.d/50-jenkins-agent.conf` so needrestart
never restarts the agent. Security updates still install; the agent picks up new libraries when it is
restarted by hand while no build is running (`sudo systemctl restart jenkins-agent`). Build re-run afterwards.

**Lesson:** when a test fails with an error that makes no sense for the code, read the lines just above it.
Here the real event was the agent going offline, and the cause was outside Jenkins entirely.

### Issue 15 — Build #7 security scan failed: new CVE in apt inside the Python base image

**Symptom:** build #7 passed Checkout, Build and Test, then stopped at Security scan; nothing was deployed.

```text
==> scan chat-api:47c7ec5 (fails on HIGH/CRITICAL with a fix available)
localhost:5000/chat-api:47c7ec5 (debian 13.7)
Total: 2 (HIGH: 2, CRITICAL: 0)
│ apt           │ CVE-2026-109518 │ HIGH │ fixed │ 3.0.3 │ 3.0.4 │ On Debian, Ubuntu, and derivative Linux distributions, an on-path atta ...
│ libapt-pkg7.0 │                 │      │       │       │       │
```

**Cause:** no code change. The CVE was published overnight; Debian already shipped apt 3.0.4 in
`stable-security`, but the `python:3.12-slim` base image had not been rebuilt with it yet. The UI image
(Alpine, already running `apk upgrade`) was clean.

**Fix:** the chat-api runtime stage runs `apt-get update && apt-get upgrade -y` (upgrades only, no new
packages, apt lists removed afterwards), the same approach the UI image uses with `apk upgrade`.
Rebuilt and rescanned: 0 HIGH/CRITICAL in both images.

**Lesson:** the scan doing its job. A pipeline that blocks on new CVEs will stop on days when nothing in the
code changed; pulling the distribution's security fixes at build time keeps it green without ignoring anything.

### Issue 16 — Build #8 failed before any stage: Jenkins couldn't reach GitHub

**Symptom:** build #8 (started 06:25 UTC by the push of `a976b13`) failed in about a minute, before Checkout. Jenkins
could not load the Jenkinsfile:

```text
hudson.plugins.git.GitException: Command "git fetch --tags --force --progress --prune -- origin +refs/heads/master:refs/remotes/origin/master" returned status code 128:
stderr: ssh: connect to host github.com port 22: Network is unreachable
fatal: Could not read from remote repository.
```

**What we know:** the same commit had been pushed from this server two minutes earlier, so the host had internet
access. The system log shows Wi-Fi connected the whole time (last rekey 06:17, next disconnect 06:47), and no
link or DHCP change at 06:25. "Network is unreachable" means the Jenkins pod had no route at that moment, so the
problem was on the pod or cluster network side, not GitHub or the deploy key.

**Cause:** not confirmed; the error did not recur. Later that morning the server was shut down (09:48 UTC) and
came back at 14:06 with a new LAN address (192.168.1.104 on the wired port).

**Resolution:** build #9 ran the same commit after the restart and passed every stage, including prod.

**Lesson:** a failure before Checkout says nothing about the code, so check whether the next run of the same
commit passes before changing anything. If it happens again, run `kubectl -n ci exec deploy/jenkins -- ip route`
and a test `git ls-remote` from the pod while it is failing.

### Issue 17 — Builds #10 and #11 failed "Architecture page served" in dev and rolled back

**Symptom:** the push adding the Architecture page (`3ab766b`) passed Build, Test, the Trivy scan and SBOM, then
failed in Deploy dev. Exactly one of the 25 checks failed, a new one added in the same commit:

```text
PASS  Pulse page served
FAIL  Architecture page served
...
passed: 24   failed: 1
!! verification failed in dev: rolling back to revision 15
!! dev is back on revision 15. 3ab766b was NOT kept. Fix the failure and push again.
```

Automatic rollback (Issue 12) worked: dev went back to the previous release and qa and prod were never touched.
Build #11, started by hand for the same commit, failed the same way.

**Checks that ruled things out:**
- The image the pipeline built was fine: run on its own, `localhost:5000/ui:3ab766b` served `/architecture/` with
  200 and the right title, and the strict CSP stayed intact.
- Ingress and Helm were fine: the ingress sends every path except `/api` to the ui.
- After deploying `3ab766b` to dev by hand, the page answered 200 (48 KB) every time.

**Cause:** two things, both fixed:
1. **`grep -q` + `pipefail` again (Issue 6).** The check was
   `curl -sf $URL/architecture/ | grep -q '<title>Architecture'`. `grep -q` stops reading at the first match, near
   the top of the 48 KB page. Over TLS the page arrives in chunks, so curl is often still writing and fails, and
   with `pipefail` the whole check fails. The Pulse page passes the same pattern because it is small. Build #11
   proves this: dev was already serving the page when its check ran, and the check still failed. It's a race,
   so the same command often passes when run by hand.
2. **Old pods still answering just after the rollout.** Verification starts once the app answers steadily, but
   that wait only probes `/` and `/api/status`, which the old release also serves. Requests that reach a
   terminating old ui pod get its fallback `index.html` for `/architecture/` (no "Architecture" title).

**Fix (commit `ceda217`):**
- The check reads the whole body: `grep '<title>Architecture' >/dev/null`, the same as the Journal check.
- `scripts/07-verify.sh` first waits (up to 60 s) until no pod in the namespace is terminating, then runs the
  steady-answer wait and the checks. Every check now tests the new release only.

Build #12 passed all 25 checks in dev, qa and prod; prod was approved by admin and runs `ceda217`.

**Lesson:** a check for a new page or feature can't pass against the old release, so verification must not start
until the old pods are gone. And with `pipefail`, never put `grep -q` or `head` after curl.

### Issue 18 — Mistakes: a known issue repeated, a wrong first diagnosis, two deploys to dev at once

**What happened:**
- **The check repeated Issue 6.** That entry already says to avoid `grep -q` after curl under `pipefail`, but the new
  check was copied from the Pulse line, which uses `grep -q` and only passes because Pulse's response is small.
- **The first diagnosis was dropped too early.** `grep -q` was the first suspect, but a local test (plain HTTP,
  page fits in the pipe buffer) passed, so it was set aside for the "old pods" theory. Build #11's failure, with the
  page already live in dev, showed that both causes were real.
- **Two deploys to dev at once.** While investigating, `3ab766b` was deployed to dev by hand at 14:59. At the same time
  build #11, started from the Jenkins UI at 14:57, was deploying the same commit to dev, so the two deploys
  overlapped. No harm done (same image, dev only), but the result of each one was harder to read.

**Fix:** the Pulse check was left alone (it passes reliably), but every new check uses `grep ... >/dev/null`.
Before deploying by hand, check that no pipeline build is running:
`curl ... /job/chatbot/lastBuild/api/json?tree=building`.

**Lesson:** read the existing issues log before adding a check. When a local test clears a suspect, ask whether
it reproduced the real conditions (TLS, chunked transfer, timing) before moving on.

### Issue 19 — First backup job: "Connection refused" from Postgres

**Symptom:** the first `make backup-now` failed three times in a row within seconds:

```text
pg_dumpall: error: connection to server at "postgres.data.svc.cluster.local" (10.43.203.19), port 5432 failed: Connection refused
!! job backup-manual-20261105152401 did not complete (FailureTarget Failed)
```

**Cause:** the known k3s gap from the README's security notes: network rules for a brand-new pod are applied a
few seconds after it starts. Until then the new backup pod's traffic is refused. The job connected immediately,
and each retry was again a new pod, so all three attempts fell into that window. The rules themselves were
right (`postgres-allow-backup`, `postgres-backup-egress`).

**Fix:** the backup script (and the restore job) first waits up to 60 s for `pg_isready`, then starts. The next
run made a complete backup in 8 s; the restore test then passed for all three databases.

**Also found while setting up:** YAML anchors (`&podsec` / `*podsec`) don't work across the `---` documents of
one file; `kubectl apply --dry-run=server` caught it before anything was applied. The settings are written out
in full in each job.

**Lesson:** any short-lived pod that talks over the network right at start-up (jobs, probes) must wait for its
target first. The verify script's probe pod already did, for the same reason.

### Issue 20 — Postgres TLS check: "Connection refused" from inside the Postgres pod

**Date:** 9 November 2026, first run of `make db-tls` (Phase 5 home side).

**Symptom:** Postgres restarted with TLS on and the first two checks passed, then the script stopped with no
message. Running the check by hand showed:

```text
psql: error: connection to server at "postgres.data.svc.cluster.local" (10.43.203.19), port 5432 failed: Connection refused
```

**Cause:** two problems.
- **The check ran in the wrong pod.** It used `kubectl exec` into `postgres-0` and connected to the Service
  from there. The `data` namespace denies all outgoing traffic by default (only DNS is allowed), so the
  Postgres pod may not open a connection, not even to itself. k3s refuses those packets, which looks like
  "Connection refused". Postgres itself was fine: the app pods had already reconnected over TLS 1.3.
- **A failed check stopped the script.** The result was read with `got=$(...)` under `set -e`, so the
  non-zero exit ended the script before `check` could print FAIL.

**Fix:** the network check now runs in a short-lived probe pod with the backup job's label, which may reach
Postgres on 5432 and nothing else. It waits for `pg_isready` first (Issue 19), then connects with
`sslmode=verify-full` against the local CA. Command results are read with `|| true`, so a failure is
reported as FAIL and the remaining checks still run. Second run: 9 of 9 passed, `make verify ENV=dev` 25 of 25.

**Also noted:** `kubectl apply` warns that `spec.externalIPs` (used by the `postgres-tunnel` Service on
`10.200.0.1`) is deprecated. k3s still supports it; the tunnel test will confirm it end to end, with a host
port rule as the fallback.

**Lesson:** test a network path from a pod that is meant to use it. The default-deny rules apply to the
server's own pod too.

### Issue 21 — Tunnel test: AWS node setup did not finish, then a false handshake failure

**Date:** 9 November 2026, first `make tunnel-test` (Phase 5).

**Symptom 1:** the test stopped while waiting for the AWS node:

```text
==> waiting for the AWS node to register with SSM and finish setup
node setup (user data) did not finish
```

**Cause:** the node's boot log (`aws ec2 get-console-output`) showed the kernel killing the package installer:

```text
dnf invoked oom-killer ...
Out of memory: Killed process 2065 (dnf) ...
part-001: line 48:  2065 Killed    dnf install -y -q postgresql16
```

A t4g.nano has 512 MB and no swap, and `dnf` loading the package lists needs more. WireGuard had already been
set up by then (it comes first in the user data), so only the Postgres client and the "ready" marker were missing.

**Fix:** the user data now makes a 1 GB swap file before `dnf`. The running node was finished over SSM instead
of being rebuilt, which would have changed its public IP and the home `wg0.conf`. A slip on the way: the first
SSM attempt failed because Amazon Linux's `mkswap` has no `-q` option; it now sends the output to `/dev/null`.

**Symptom 2:** the next run passed six checks and failed one:

```text
FAIL  WireGuard handshake with home (latest: 'none')
PASS  home end of the tunnel answers ping
```

**Cause:** a mistake in the test. It read the handshake time with `wg show`, but the AWS node runs WireGuard
through systemd-networkd and has no `wg` tool, so the answer was always empty. The passing ping already proved
the tunnel.

**Fix:** that check was replaced by a stronger one on the home side: Postgres must log the caller as
`10.200.0.2`. This proves the tunnel address survives the trip (no NAT in between), which `pg_hba.conf` and the
NetworkPolicy depend on. Third run: 7 of 7 passed.

**Lesson:** size even a throwaway node for the tools it installs, and make each check depend only on tools that
are known to be on the machine it runs on.

### Issue 22 — First `make burst-up` stopped with exit code 141 while making the join token

**Date:** 9 November 2026, first run of `make burst-up` (Phase 6).

**Symptom:** the script stopped right after its second step, with no error message of its own:

```text
==> cluster side: priority class, burst quotas, Prometheus cloud label
==> keys and a one-hour join token
make: *** [Makefile:92: burst-up] Error 141
```

**Cause:** a mistake in the script. Exit code 141 is 128 + 13, a process killed by SIGPIPE. The random parts of the
k3s join token were made with `tr -dc 'a-z0-9' </dev/urandom | head -c 6`. `head` exits after 6 characters and
closes the pipe; `tr` is still writing, so the kernel kills it with SIGPIPE. That is normal for this idiom, but the
script runs with `set -o pipefail`, which reports the pipeline as failed, and `set -e` then ends the script.

**Impact:** none. It stopped before the token Secret was created and before Terraform ran, so nothing was left in
the cluster or in AWS (checked: no secret labelled `qwenops.io/burst=true`, no Terraform state).

**Fix:** the two values now come from `openssl rand -hex 3` and `openssl rand -hex 8`, which need no pipe. Hex
digits fit the bootstrap token format (`[a-z0-9]{6}.[a-z0-9]{16}`), checked before the rerun. No other line in
`scripts/13-burst.sh` pipes into `head`.

**Lesson:** under `set -o pipefail`, don't pipe an endless producer (`/dev/urandom`, `yes`, `cat` of a stream) into
`head`. Use a command that makes exactly what is needed (`openssl rand`), or read a fixed number of bytes
(`head -c 16 /dev/urandom | ...` with `head` first).

### Issue 23 — `burst-up`: AWS refused "terminate on shutdown" for a Spot instance

**Date:** 9 November 2026, second run of `make burst-up` (Phase 6).

**Symptom:** Terraform created the Spot instance, then failed 50 seconds later:

```text
Error: modifying EC2 Instance (i-034e9ba04b2391954) InstanceInitiatedShutdownBehavior attribute:
api error UnsupportedOperation: Modifying 'instanceInitiatedShutdownBehavior' is not supported for spot instances.
```

**Cause:** a mistake in the Terraform. `instance_initiated_shutdown_behavior = "terminate"` was set so the idle and
max-lifetime timers' `shutdown` ends billing. For Spot, the AWS provider sets that attribute in a second call after
launch, and AWS refuses it. It isn't needed: a one-time Spot instance always terminates on shutdown. Checked on the
instance that was created: `describe-instance-attribute` returned `terminate`.

**Impact:** the instance kept running (about half a cent) and Terraform marked it as failed ("tainted"), so the
next run would replace it. The join token from the run stayed in the cluster until it expired.

**Fix:** the attribute is set only for on-demand (`var.spot ? null : "terminate"`). It now lives in the launch
template (Issue 25), with the same rule.

**Lesson:** for Spot, check which instance settings AWS accepts. `terraform validate` can't catch it; only a real
apply (or the AWS docs) does.

### Issue 24 — `burst-up`: AppArmor stopped `wg-quick` from starting the registry copy

**Date:** 9 November 2026, third run of `make burst-up`.

**Symptom:** the AWS node was created, then bringing up `wg0` at home failed and rolled itself back:

```text
[#] docker run -d --rm --name registry-tunnel -p 10.200.0.1:5000:5000 ... registry:2
/usr/bin/wg-quick: line 296: /usr/bin/docker: Permission denied
[#] ip link delete dev wg0
make: *** [Makefile:92: burst-up] Error 126
```

**Cause:** the read-only registry copy was started from `wg0.conf`'s `PostUp` line, which `wg-quick` runs as root.
Ubuntu ships an AppArmor profile for `wg-quick` (`/etc/apparmor.d/wg-quick`), and it doesn't allow running `docker`.
The kernel log showed it:

```text
apparmor="DENIED" operation="exec" class="file" profile="wg-quick" name="/usr/bin/docker" ... comm="wg-quick"
```

Root being refused is the hint: plain file permissions never stop root, AppArmor does. Exit code 126 means
"found but not allowed to run".

**Fix:** the profile was left alone (it's a sensible limit). `scripts/13-burst.sh` now starts the registry copy
itself, as the user (who is in the `docker` group), right after `wg0` is up, and removes it before `wg0` goes down.
The `PostUp`/`PreDown` lines are gone from the generated `wg0.conf`. The AWS node from that run was kept: the
already-written `wg0.conf` was cleaned, `sudo wg-quick up wg0` and `make burst-ready` finished the bring-up, and the
node joined.

**Lesson:** on Ubuntu 25.10+, many system tools run under their own AppArmor profiles. Keep hooks like `PostUp` to
networking commands; run anything else from the script that calls `wg-quick`. When root gets "Permission denied",
check `journalctl -k | grep DENIED` first.

### Issue 25 — Spot machine taken back after 7 minutes; three checks failed

**Date:** 9 November 2026, first `make burst-test`.

**Symptom:** seven checks passed and three failed:

```text
PASS  AWS node joined and Ready
PASS  node labelled cloud=aws
PASS  node tainted: burst pods only
PASS  ollama-burst ready on the AWS node
PASS  chat-api-burst pods ready on the AWS node (db + model reachable)
FAIL  burst pods' Postgres connections: 0 of 0 over TLS
FAIL  no answer from ollama-burst
PASS  only burst pods on the AWS node
PASS  burst pods use the burst quota, not prod's
FAIL  Capacity page shows the AWS node (got 'False', want 'True')
```

At the same moment `make burst-status` showed the AWS machine as `shutting-down`.

**Cause:** AWS took the Spot machine back. It launched at 08:33:18 UTC and was terminated at 08:40:30:

```text
Server.SpotInstanceTermination: Spot instance termination
instance-terminated-no-capacity: Your Spot instance was terminated because there is no Spot capacity available
that matches your request.
```

Our own timers were not involved: the boot log showed the max-lifetime shutdown set for 14:33, and the idle check
waits 20 minutes after boot. The request allowed exactly one type (c6a.xlarge) in one zone (ap-south-1a), so when
that pool ran short there was nowhere else to go. The three failures came after the machine was already gone; the
node still showed "Ready" because Kubernetes takes about 40 seconds to notice a lost node.

**What the 7 minutes proved:** the node joined k3s over the tunnel with the right labels and taint, and all three
burst pods became ready. Their readiness check needs Postgres at home and the AWS Ollama, so pod traffic between
home and AWS (flannel VXLAN inside WireGuard) works, which was the main risk in the design.

**Fix:**
- the node now comes from an **EC2 Fleet** (`type = "instant"`) instead of one `aws_instance`: a launch template
  plus 10 allowed types (c6a, m6a, c5a, m5a, m5, c5, c7i, m6i, c6i, m7i `.xlarge`, all amd64 with 4 vCPU, 0.051 to
  0.081 USD an hour as Spot) in **all three zones** (one subnet each), with AWS's `price-capacity-optimized`
  strategy. AWS's Spot placement score for this mix is 9 of 10 in every zone (one type in one zone is what failed).
- `make burst-status` shows which type and zone AWS picked.
- `make burst-test` now first checks that the AWS machine is still running, and if not prints why (for example the
  Spot message above) instead of three confusing failures.
- clean-up: `make burst-down` removed the dead node, the burst pods, `wg0` and everything in AWS.

**Lesson:** a Spot request should always allow several types and zones; a single pool can run dry at any time.
And a test should check its foundation first (is the machine there?) before checking what runs on it.

### Issue 26 — EC2 Fleet refused three times: "minimum target capacity"

**Date:** 9 November 2026, the first three `make burst-up` runs after switching to an EC2 Fleet (Issue 25).

**Symptom:** each run created the network and launch template, then the fleet failed:

```text
1st and 2nd run:
api error InvalidParameterCombination: The minimum target capacity is only available with single instance fleets
or single AZ fleets.
3rd run:
api error InvalidParameterValue: Theminimum target capacity should be larger than or equal to 1.
```

**Cause:** the fleet allows 10 instance types in 3 zones and set no minimum capacity. But the AWS provider always
sends a minimum target capacity in the fleet's Spot (and on-demand) settings block, 0 when it isn't set. AWS accepts
that field only from a fleet marked "single instance type" or "single zone", and only when it is at least 1. The
plan doesn't show it (zero values are hidden), and `aws ec2 create-fleet --dry-run` passed every variant tried, so
only a real apply showed the error.

**What happened on the way (a mistake):**
1. **Wrong guess.** After the first error, the on-demand settings block (present even for Spot) was blamed and made
   to appear only for on-demand. That was not checked against anything; the second run failed the same way.
2. **Checked instead of guessed.** `terraform providers schema -json` showed that the Spot block also has
   `min_target_capacity`, so it was the Spot block sending 0. Setting `single_instance_type = true` got past the
   first rule, and the third run hit the second rule (minimum must be at least 1).
3. **Both settings.** Now both blocks set `single_instance_type = true` and `min_target_capacity = 1`.

**Why that's fine:** the fleet asks for exactly one machine. "Single instance type" and "at least 1" then mean
"one machine or none"; AWS still picks it from all 10 types and 3 zones. The next run got a c6i.xlarge in
ap-south-1b. The network and launch template from the failed runs were reused, so nothing was left behind.

**Lesson:** when an API error names a field you never set, look at what the tool actually sends (the provider
schema, or `TF_LOG=DEBUG`) before changing code. One check replaced two rounds of guessing. Dry runs check
permissions, not every rule.

### Issue 27 — `burst-test` said "0 of 0" Postgres connections; the check compared addresses wrongly

**Date:** 9 November 2026, `make burst-test` after the fleet worked.

**Symptom:** ten checks passed and one failed:

```text
FAIL  burst pods' Postgres connections: 0 of 0 over TLS
PASS  model on the AWS node answers a burst pod ("hello! how can I help you today?")
```

But the burst pods were ready, and their readiness check needs Postgres.

**Cause:** a mistake in the test. It matched `pg_stat_activity.client_addr::text` against the pod IPs. `client_addr`
is a Postgres `inet` value, and as text it includes the mask: `10.42.2.3/32`, never equal to `10.42.2.3`. Postgres
had the connections all along:

```text
chat_prod|10.42.2.3|t|TLSv1.3
chat_prod|10.42.2.4|t|TLSv1.3
```

**Fix:** the check uses `host(client_addr)`, which gives the bare address. Rerun: **11 of 11 passed**, including
"burst pods use Postgres at home over TLS (2 connections)".

**Lesson:** when a check fails but a related signal (here, readiness) says the thing works, look at the raw data
before touching the system. `inet` and `cidr` values need `host()` before comparing them as text.

### Issue 28 — "Back up now" answered "no password set" and "accepted" in turns

**Date:** 9 November 2026, first end-to-end test of the Pulse backups panel on dev.

**Symptom:** right after setting a test admin password, three requests in a row gave different answers:

```text
wrong pw: {"detail":"manual backups are off (no admin password set)"}
right pw: {"accepted":true}
again:    {"detail":"manual backups are off (no admin password set)"}
```

**Cause:** setting the password restarts backup-ops. Its old pod (started without a password) kept answering for
about 30 seconds next to the new one, because the service runs Python as process 1, which ignores SIGTERM by
default: Kubernetes waited out the full 30-second grace period before killing it, and the Service sent requests to
both pods in turn. `kubectl get pods` showed the old pod "Terminating" and the new one "Running".

**Fix:** backup-ops (and later ntfy-bridge) exit at once on SIGTERM, and their Deployments use `strategy: Recreate`,
so two copies with different settings (password, wrong-guess counters) never answer at the same time. The next
restart took seconds and showed one pod.

**Lesson:** a small Python (or shell) server as PID 1 needs its own SIGTERM handler. And state kept in a pod
(counters, settings read at start) needs Recreate, not a rolling update.

### Issue 29 — Before S3 was set up, the off-site copy would hang 15 minutes on a missing secret

**Date:** 9 November 2026, same test.

**Symptom:** "Back up now" ran the backup (10 s), then started the off-site copy, which stayed `Running 0/1`.

**Cause:** the off-site job loads its S3 key from secret `offsite-s3` (`envFrom`). Before `make backup-offsite-setup`
that secret doesn't exist, so the pod can't start (`CreateContainerConfigError`) and just waits, until the job's
15-minute deadline. Meanwhile backup-ops waited on it too, and the panel showed "running".

**Fix:** the secret is now `optional: true`, so the pod starts, and the script's first line stops it at once with
`off-site copy is not set up yet: run 'make backup-offsite-setup'`. The stuck job was deleted. Retest: the chain
ended in seconds with that message, visible in the run's log on Pulse.

**Lesson:** a job that may run before its setup is done should start anyway and say what's missing, rather than
hang where only `kubectl describe` shows why.

### Issue 30 — Manual backups didn't count as the last good backup

**Date:** 9 November 2026, found while adding the backup alerts.

**Symptom:** none visible yet, but it would have been: after a "Back up now" (or `make backup-now`) the Pulse tile
and the planned BackupOverdue alert still used the last *scheduled* backup's time.

**Cause:** the status came from the CronJob's `status.lastSuccessfulTime`, which Kubernetes only updates for jobs the
CronJob itself starts. Jobs created from it by hand don't change it.

**Fix:** backup-ops takes the newest of the CronJob's time and the finish time of any successful job of that kind
(scheduled or manual). The same value feeds the Pulse tile and the new `/metrics` for the alerts. Checked in
Prometheus: backup and off-site copy showed 0.2 h old right after a manual run.

**Lesson:** "last successful run" from a CronJob means "last successful *scheduled* run". Count manual runs yourself.

### Issue 31 — Mistakes while testing alerts

**Date:** 9 November 2026, installing the ntfy alerts.

**What happened:**
1. **Broken quoting in the status command.** `make alerts-status` failed with
   `SyntaxError: unexpected character after line continuation character`: Python code inside bash single quotes
   used `\"`, which bash passes on as-is. Fixed by not needing quotes inside the f-string.
2. **Unquoted test alert text.** amtool warned that `--annotation=summary=Test alert ...` isn't valid for its new
   label parser and fell back to the old one. The values are now quoted (`'summary="..."'`).
3. **Lost the test topic.** The first delivery test created a throwaway ntfy topic in a shell variable, and the
   read-back ran in a separate command, so the name was gone and the read-back showed nothing (the bridge had logged
   `ntfy_status: 200`). The test was repeated with send and read-back in one command: the message was there.
4. **Used up the per-IP limit.** During the backups test, a run of password attempts against dev used up chat-api's
   limit (5 per 10 minutes per IP), so the "right password" got `too many attempts`. Not a bug (the limit worked),
   but it cost a retest; the chain was then tested directly against backup-ops.

**Lesson:** keep a test's setup, action and check in one command so nothing is lost between them, and count how
many attempts a test spends against a rate limit before running it.

### Issue 32 — ChatApiDown showed "pending" right after Prometheus restarted

**Date:** 9 November 2026, right after `make alerts`.

**Symptom:** `make alerts-status` listed `PENDING  ChatApiDown` although both prod pods were up.

**Cause:** Prometheus had just restarted with empty data (it keeps 24 h in an emptyDir), so for its first rule
evaluation there was no `up` series yet, and `absent(...)` was true. The rule's 2-minute `for:` stops this from
firing. Seconds later Prometheus showed both prod pods with `up = 1`, and the rule went back to inactive.

**Fix:** none needed: the `for:` delay is exactly what keeps a restart from paging anyone.

**Lesson:** rules built on `absent()` always flicker after a restart; give them a `for:` longer than one scrape
plus one evaluation.

### Issue 33 — Load test: people about to be turned away first saw "you're in line"

**Date:** 9 November 2026, first load test of overload protection on dev (1 slot, line of 2, 6 chats at once).

**Symptom:** the result was right (1 streamed, 2 waited and were answered, 3 refused in 0.2 s), but the 3 refused
ones received two events:

```text
chat 2: HTTP 200    0.2s  events=[meta,queued,error,] tokens=0 "error": "Busy right now: ..."
```

On the page that would flash "Busy right now, you're in line" and then "Busy right now ... try again".

**Cause:** all 6 arrived at the same moment, so the quick "line full?" check before the stream passed for all of
them. Inside the stream, the "queued" message was sent whenever the slot was taken, without checking whether the
line still had room.

**Fix:** "queued" is only sent when there is a place in line (`gate.must_wait() and not gate.full()`). Retest: the 3
refused chats got only the "busy" message, in 0.2 s; with the line already full, a new chat got HTTP 503 with
`Retry-After: 15` before any work.

**Lesson:** test with requests that arrive at exactly the same moment, not one after another; that's when checks
done at different times disagree.

### Issue 34 — Load retests misled: same `-dirty` image tag reused, and an old pod still serving

**Date:** 9 November 2026, retesting the fix for Issue 33.

**What happened (two mistakes):**
1. **Same tag, old image.** The rebuild of uncommitted code was tagged `439e734-dirty` again. Helm saw no change and
   kept the pods, and with `imagePullPolicy: IfNotPresent` the node would have kept its cached image anyway. The
   retest ran the old code and showed the old flash; the pod's start time (before the build) gave it away.
2. **Tested during a rollout.** After rebuilding with a unique tag (`TAG=439e734-overload2 make build`), the next
   run served all 6 chats with no "busy": the old pod was still finishing (5-second preStop) next to the new one, so
   there were two slots and two lines.

**Fix:** a unique tag for each manual rebuild of uncommitted code, and waiting until dev has exactly one API pod
before testing. The third run matched the design: 1 streamed, 2 waited (9 s and 15 s), 3 refused in 0.2 s with no
"in line" message.

**Lesson:** after a deploy, check that the pods are new (age, image) and that the old ones are gone before reading
a test result. `-dirty` tags are not unique: pass `TAG=` for every manual rebuild.

### Issue 35 — Pulse page doesn't open on a phone on the home Wi-Fi

**Date:** 9 November 2026. **Status: open** (fix written, not applied; paused at the owner's request).

**Symptom:** on a phone connected to the home Wi-Fi, `https://chatbot.local/pulse/` doesn't open.

**Cause (from the server side):** the names `chatbot.local`, `dev.chatbot.local`, `qa.chatbot.local` and
`jenkins.chatbot.local` exist only in the server's own `/etc/hosts` (pointing at 127.0.0.1), so no other device can
look them up. Phones resolve `.local` names over mDNS (Bonjour/zeroconf), and nothing announces them (avahi isn't
installed). The site itself answers on the LAN address (`https://chatbot.local` via 192.168.1.101 returned 200 from
the server). A phone also needs to trust the home CA, or it shows a certificate warning.

**Planned fix:** `scripts/16-lan-access.sh` (`make lan-access`, sudo): avahi on the LAN interface only, announcing the
four names with the current LAN address (re-announced if it changes), and ufw rules for 80/443 and mDNS (UDP 5353)
from the home subnet only. `make lan-share-ca` serves only the public CA certificate on the LAN for 10 minutes for
the phone to install. Not yet run or tested on a phone; the error the phone shows will confirm which part was
missing.
