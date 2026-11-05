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
