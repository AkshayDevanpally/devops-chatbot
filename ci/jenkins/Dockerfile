# Jenkins controller with plugins baked in: the image is immutable and scanned like the app images,
# and the controller never installs plugins at runtime. Configuration comes from JCasC (k8s/ci/20-jenkins.yaml).
# Check https://www.jenkins.io/changelog-stable/ before bumping.
FROM jenkins/jenkins:2.580.2-lts-jdk21

LABEL org.opencontainers.image.title="qwenops-jenkins" \
      org.opencontainers.image.description="Jenkins controller for the QwenOps pipeline"

COPY --chown=1000:1000 plugins.txt /usr/share/jenkins/ref/plugins.txt
# Trivy does not open .jpi plugin files, so check plugins against the Jenkins security advisories
# instead: any warning ("<plugin> - <issue>") for the versions being installed fails the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt --view-security-warnings 2>&1 \
      | tee /tmp/plugins.log \
 && if grep -E '^[A-Za-z0-9_.-]+ - ' /tmp/plugins.log; then echo "!! plugin security warnings"; exit 1; fi \
 && rm /tmp/plugins.log

# Remove what the running controller never uses, to shrink the attack surface (and clear their CVEs):
#   jenkins-plugin-manager.jar - build-time plugin installer (used above)
#   git-lfs                    - this repo has no LFS files
USER 0
# Pull Debian security fixes the Jenkins base image hasn't been rebuilt with yet (keeps Trivy green, e.g.
# CVE-2026-109518 in apt, CVE-2026-76844/-85091 in zlib1g). Upgrades only: no new packages. Same as chat-api.
# hadolint ignore=DL3005
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /opt/jenkins-plugin-manager.jar /usr/bin/jenkins-plugin-cli /usr/local/bin/git-lfs
USER 1000
