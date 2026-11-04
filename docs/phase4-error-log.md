# Phase 4 — Error log by stage

Every error and warning hit while setting up Jenkins and running the pipeline, grouped by stage.
All times are UTC on 4 November 2026. Explanations and lessons: [phase4-issues.txt](phase4-issues.txt).

**Status key:** ✅ passed · ❌ failed · ⚠️ warning (did not fail) · ℹ️ false alarm

## Overview

| # | Part | Stage | Result | Error in one line | Fix |
|---|---|---|---|---|---|
| E1 | Setup | Controller image scan | ❌ | Trivy `context deadline exceeded` | `--timeout 20m` |
| E2 | Setup | Controller image scan | ❌ | 12 HIGH CVEs in the Jenkins image | Removed unused tools; 1 expiring exception |
| E3 | Setup | Controller image scan | ⚠️ | Plugins (`.jpi`) not scanned at all | Plugin advisory check in the image build |
| E4 | Setup | Controller deploy | ❌ | JCasC `UnknownAttributesException`, CrashLoopBackOff | Removed 2 obsolete settings |
| E5 | Setup | Controller deploy | ❌ | `make jenkins` rollout timed out | Caused by E4 |
| E6 | Setup | Post-deploy checks | ℹ️ | Jobs/nodes API returned nothing | `curl -g` (globbing) |
| E7 | Setup | Post-deploy checks | ℹ️ | Deployer `can-i create pods/exec` = yes | Use `--subresource=exec` → no |
| E8 | Access | Browser | ❌ | `404 page not found` via port forward | Browse by hostname, not localhost |
| E9 | Pipeline | Build #1 · Load Jenkinsfile | ❌ | `Permission denied (publickey)` | Added the GitHub deploy key |
| E10 | Pipeline | Build #2 · Test | ⚠️ | pip "running as root" warning | None needed (throwaway container) |
| E11 | Tooling | Build watcher | ❌ | Watcher silent for the whole build | Python quoting error hidden by `2>/dev/null` |

---

## Part A — Setup (`make jenkins`)

### E1 · Controller image scan — Trivy timeout ❌

| Field | Value |
|---|---|
| Time | 05:46:08 |
| Command | `trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 localhost:5000/jenkins:test` |
| Cause | Default 5-minute limit; the first Java scan also downloads the Java vulnerability DB |
| Fix | `--timeout 20m` in `scripts/09-jenkins.sh` |
| Note | The command was piped into `tail`, so the shell reported `exit=0` despite the failure |

```text
2026-11-04T05:46:08Z  FATAL  Fatal error  run error: image scan error: scan error: scan failed:
failed analysis: analyze error: pipeline error: failed to analyze layer
(sha256:166daa7b2e1397f734e9aa760f0535395743b08793b988714a77a806dc89b6a3): post analysis error:
post analysis error: walk dir error: walk error: context deadline exceeded
```

### E2 · Controller image scan — HIGH vulnerabilities ❌

| Field | Value |
|---|---|
| Time | ~05:50 |
| Result | `trivy exit=1`: 12 HIGH, 0 CRITICAL |
| Fix | Removed `/opt/jenkins-plugin-manager.jar` and `/usr/local/bin/git-lfs`; guava accepted until 2026-12-15 (`ci/jenkins/.trivyignore`) |
| After fix | `Vulnerabilities: 0` for the OS packages and `jenkins.war` |

| Component (file) | Package | Installed | Fixed in | CVEs | Action |
|---|---|---|---|---|---|
| `/opt/jenkins-plugin-manager.jar` | jackson-core | 2.20.1 | 2.21.4 | 3 | Removed file (build-time only) |
| `/opt/jenkins-plugin-manager.jar` | jackson-databind | 2.20.1 | 2.21.4 / 3.1.4 | 5 | Removed file (build-time only) |
| `/usr/local/bin/git-lfs` | golang.org/x/crypto | v0.54.0 | 0.55.0 | 1 (CVE-2026-56854) | Removed file (no LFS used) |
| `/usr/local/bin/git-lfs` | golang.org/x/net | v0.57.0 | 0.60.0 | 1 (CVE-2026-78669) | Removed file |
| `/usr/local/bin/git-lfs` | golang.org/x/text | v0.40.0 | 0.41.0 | 1 (CVE-2026-56851) | Removed file |
| `jenkins.war` (Jenkins core) | guava | 33.7.1-jre | 33.7.2 | 1 (CVE-2026-102554, DoS) | Accepted, expires 2026-12-15 |

```text
usr/local/bin/git-lfs (gobinary)
================================
Total: 3 (HIGH: 3, CRITICAL: 0)
│ golang.org/x/crypto │ CVE-2026-56854 │ HIGH │ fixed │ v0.54.0 │ 0.55.0 │ golang.org/x/crypto/ssh:
│                     │                │      │       │         │        │ Authentication bypass due to
│                     │                │      │       │         │        │ unenforced source-address restrictions
│ com.google.guava:guava (jenkins.war) │ CVE-2026-102554 │ 33.7.1-jre │ 33.7.2 │ Google Guava: Denial of
│                                      │                 │            │        │ Service via unthrottled memory
│                                      │                 │            │        │ allocation during deserialization
```

### E3 · Controller image scan — plugins never scanned ⚠️

| Field | Value |
|---|---|
| Time | ~05:53 |
| Symptom | Scan passed, but the report listed only the OS packages and `jenkins.war`, no plugins |
| Check | `trivy image --list-all-pkgs`: 134 Java packages, all under `/usr/share/jenkins` (war); 0 from the 67 `.jpi` plugins |
| Cause | Trivy reads `.jar/.war/.ear` only; Jenkins plugins are `.jpi` |
| Fix | Image build runs `jenkins-plugin-cli --view-security-warnings`; any `<plugin> - <issue>` line fails the build |
| Result | No advisories for the 7 requested plugins and their dependencies |

```text
$ trivy image --list-all-pkgs ... (summary)
localhost:5000/jenkins:test (debian 13.7)   131 packages
Java                                        134 packages   paths: usr/share/jenkins (jenkins.war only)
$ ls /usr/share/jenkins/ref/plugins | wc -l
67
```

### E4 · Controller deploy — JCasC rejected, CrashLoopBackOff ❌

| Field | Value |
|---|---|
| Time | 05:57:18 (first failure), pod restarted 6 times in ~10 min |
| Pod | `ci/jenkins-7f445b5cdf-hdbw8`: `CrashLoopBackOff` |
| Cause | Settings removed from current Jenkins: `crumbIssuer.standard.excludeClientIPFromCrumb`, `remotingSecurity` |
| Fix | Removed both from `k8s/ci/20-jenkins.yaml`; tested locally in Docker → `Jenkins is fully up and running` (06:00:43) |

```text
2026-11-04 05:57:18.956+0000 [id=31] SEVERE jenkins.InitReactorRunner$1#onTaskFailed: Failed ConfigurationAsCode.init
io.jenkins.plugins.casc.UnknownAttributesException: standard: Invalid configuration elements for type:
  class hudson.security.csrf.DefaultCrumbIssuer : excludeClientIPFromCrumb.
Caused: io.jenkins.plugins.casc.ConfigurationAsCodeBootFailure
Caused: java.lang.reflect.InvocationTargetException
Caused: java.lang.Error
2026-11-04 05:57:18.957+0000 [id=24] SEVERE hudson.util.BootFailure#publish: Failed to initialize Jenkins
```

Kubernetes events while it crashed:

```text
Warning  Unhealthy  Startup probe failed: HTTP probe failed with statuscode: 503
Warning  Unhealthy  Startup probe failed: Get "http://10.42.0.54:8080/login": dial tcp 10.42.0.54:8080: connect: connection refused
Warning  BackOff    Back-off restarting failed container jenkins in pod jenkins-7f445b5cdf-hdbw8_ci
```

### E5 · Controller deploy — `make jenkins` timed out ❌

| Field | Value |
|---|---|
| Time | ~06:00 |
| Cause | Result of E4: the pod never became ready |
| Fix | Re-ran `./scripts/09-jenkins.sh` after fixing JCasC → `deployment "jenkins" successfully rolled out`, `certificate/jenkins-tls condition met` |

```text
Waiting for deployment "jenkins" rollout to finish: 0 of 1 updated replicas are available...
error: timed out waiting for the condition
make: *** [Makefile:35: jenkins] Error 1
```

### E6 · Post-deploy checks — empty API output ℹ️

| Field | Value |
|---|---|
| Command | `curl -u admin:… "http://…/api/json?tree=jobs[name]"` |
| Symptom | Printed nothing (looked like "no jobs, no nodes") |
| Cause | curl URL globbing: `[name]` parsed as a pattern, request never sent |
| Fix | `curl -g …` → `{"jobs":[{"name":"chatbot"}]}`, nodes: `Built-In Node`, `host-agent` |

### E7 · Post-deploy checks — "deployer can exec into pods" ℹ️

| Field | Value |
|---|---|
| Command | `kubectl auth can-i create pods/exec -n chatbot-dev --as=system:serviceaccount:ci:jenkins-deployer` |
| Output | `yes` |
| Cause | `pods/exec` = pod **named** "exec"; the account may create pods |
| Correct check | `kubectl auth can-i create pods --subresource=exec …` → `no` (attach `no`, portforward `no`) |

Full permission check of the deploy account (correct form):

| Check | Expected | Result |
|---|---|---|
| create deployments in chatbot-dev | yes | yes ✅ |
| get secrets in chatbot-prod (Helm storage) | yes | yes ✅ |
| create pods in chatbot-qa (verify probes) | yes | yes ✅ |
| get secrets in data | no | no ✅ |
| get secrets in ci | no | no ✅ |
| create deployments in ai | no | no ✅ |
| create clusterrolebindings | no | no ✅ |
| create rolebindings in chatbot-dev | no | no ✅ |
| get nodes | no | no ✅ |
| pods exec / attach / portforward | no | no ✅ |

---

## Part B — Access

### E8 · Browser — `404 page not found` through port forwarding ❌

| Field | Value |
|---|---|
| Setup | VS Code forwards remote port 443 to the laptop |
| Symptom | Traefik's plain `404 page not found` |
| Cause | Browser opened `https://localhost`; Traefik routes by hostname |
| Fix | Laptop hosts file `127.0.0.1 jenkins.chatbot.local …`, then type `https://jenkins.chatbot.local` |

Reproduced on the server:

| Address | HTTP status |
|---|---|
| `https://localhost/` | 404 |
| `https://127.0.0.1/` | 404 |
| `https://jenkins.chatbot.local/` | 200 |
| `https://jenkins.chatbot.local:8443/` (Host header with port) | 200 |

---

## Part C — Pipeline runs

### Build #1 — ❌ FAILURE (06:02:06, 1.7 s)

Triggered by the push to `master`, before the deploy key was on GitHub. It failed while loading the
Jenkinsfile, before any stage started.

| Stage | Result | Duration |
|---|---|---|
| Load Jenkinsfile from GitHub | ❌ | 1.7 s |
| Checkout … Ship to prod | not run | — |

#### E9 · Load Jenkinsfile — `Permission denied (publickey)`

| Field | Value |
|---|---|
| Cause | Jenkins' read-only deploy key not yet added to the repo |
| Fix | Repo → Settings → Deploy keys → added `jenkins-deploy@qwenops` (read-only) |
| Check | `git ls-remote` with the deploy key → `d1cdac05… refs/heads/master` |

```text
Started by an SCM change
hudson.plugins.git.GitException: Command "git fetch --tags --force --progress --prune -- origin
  +refs/heads/master:refs/remotes/origin/master" returned status code 128:
stdout:
stderr: git@github.com: Permission denied (publickey).
fatal: Could not read from remote repository.

Please make sure you have the correct access rights
and the repository exists.
	at ...CliGitAPIImpl.launchCommandIn(CliGitAPIImpl.java:2852)
	at ...GitSCMFileSystem$BuilderImpl.build(GitSCMFileSystem.java:409)
	at ...CpsScmFlowDefinition.create(CpsScmFlowDefinition.java:123)
Finished: FAILURE
```

### Build #2 — ✅ SUCCESS (started 06:27:29, 18 min 5 s, commit `d1cdac0`)

Started manually ("Build Now"). Approved for prod by `admin` at 06:41:59.

| # | Stage | Result | Duration | Key output |
|---|---|---|---|---|
| 1 | Checkout | ✅ | 12 s | `Obtained Jenkinsfile from git git@github.com:AkshayDevanpally/devops-chatbot.git` |
| 2 | Build | ✅ | 116 s | chat-api and ui images built; hadolint clean |
| 3 | Test | ✅ | 115 s | ruff + pytest passed; `1 chart(s) linted, 0 chart(s) failed` × 3 |
| 4 | Security scan | ✅ | 129 s | Trivy: no fixable HIGH/CRITICAL in chat-api or ui |
| 5 | Sign & box | ✅ | 16 s | `sbom/chat-api-d1cdac0.spdx.json`, `sbom/ui-d1cdac0.spdx.json`; `Pushed tag d1cdac0` |
| 6 | Deploy dev | ✅ | 223 s | `Deployed d1cdac0 to dev`; verify `passed: 22 failed: 0` |
| 7 | Deploy qa | ✅ | 203 s | `Deployed d1cdac0 to qa`; verify `passed: 22 failed: 0` |
| 8 | Ship to prod | ✅ | 253 s | `Approved by admin`; `Deployed d1cdac0 to prod`; verify `passed: 22 failed: 0` |

#### E10 · Test — pip warning ⚠️

| Field | Value |
|---|---|
| Time | 06:31:42 |
| Source | `scripts/test.sh` installs test dependencies inside a throwaway `python:3.12-slim` container |
| Impact | None: the container is deleted after the tests |
| Optional fix | Add `--root-user-action=ignore` to the `pip install` in `scripts/test.sh` |

```text
[2026-11-04T06:31:42.069Z] WARNING: Running pip as the 'root' user can result in broken permissions and
conflicting behaviour with the system package manager, possibly rendering your system unusable.
It is recommended to use a virtual environment instead: https://pip.pypa.io/warnings/venv.
```

#### Timing note (not an error)

About 10 of the 18 minutes are `make verify` (≈3 min per environment). The four network probes each
wait 10 s for the k3s policy engine plus pod start-up. Running them from one pod in parallel would
save several minutes per build.

---

## Part D — Tooling

### E11 · Build watcher stayed silent ❌

| Field | Value |
|---|---|
| What | Background script polling `/job/chatbot/2/wfapi/describe` to report each stage |
| Symptom | No events for the whole 18-minute build, even after it finished |
| Cause | Escaped quotes inside a single-quoted Python snippet → `SyntaxError`; stderr sent to `/dev/null`, so the watcher printed nothing instead of failing |
| Fix | Read the stage results directly from the Jenkins API; watcher stopped |
| Lesson | Test a watcher by hand once; never hide the error output of its main step |
