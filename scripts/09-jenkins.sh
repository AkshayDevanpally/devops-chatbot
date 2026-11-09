#!/usr/bin/env bash
# Phase 4: Jenkins controller in k3s (namespace ci). Re-runnable.
#   REPO_URL=git@github.com:<you>/<repo>.git ./scripts/09-jenkins.sh
# (REPO_URL defaults to this checkout's "origin" remote; GIT_BRANCH defaults to master.)
# Then: make jenkins-agent (sudo) to connect the build agent on this host.
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-localhost:5000}"
REPO_URL="${REPO_URL:-$(git remote get-url origin 2>/dev/null || true)}"
GIT_BRANCH="${GIT_BRANCH:-master}"
[[ $REPO_URL =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  echo "REPO_URL must be an SSH GitHub URL, e.g. REPO_URL=git@github.com:<you>/<repo>.git (got: '${REPO_URL}')"; exit 1; }

echo "==> controller image (plugins baked in)"
VERSION=$(sed -n 's/^FROM jenkins\/jenkins:\([0-9.]*\)-.*/\1/p' ci/jenkins/Dockerfile)
HASH=$(cat ci/jenkins/Dockerfile ci/jenkins/plugins.txt | sha256sum | cut -c1-8)
IMAGE="$REGISTRY/jenkins:$VERSION-$HASH"
if docker manifest inspect --insecure "$IMAGE" >/dev/null 2>&1; then
  echo "$IMAGE already in the registry"
else
  docker build --pull -t "$IMAGE" ci/jenkins
  if command -v hadolint >/dev/null; then hadolint ci/jenkins/Dockerfile; fi
  if command -v trivy >/dev/null; then
    echo "==> scan $IMAGE (fails on HIGH/CRITICAL with a fix available)"
    # Jenkins has hundreds of plugin jars to analyse: allow longer than the 5-minute default.
    trivy image --quiet --timeout 20m --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
      --ignorefile ci/jenkins/.trivyignore "$IMAGE"
  fi
  docker push "$IMAGE"
fi

echo "==> namespace, quota, network policies, deployer account"
kubectl apply -f k8s/ci/00-namespace.yaml -f k8s/ci/10-deployer-rbac.yaml

echo "==> secrets (generated into the cluster, never written to disk)"
if kubectl -n ci get secret jenkins-secrets >/dev/null 2>&1; then
  echo "jenkins-secrets exists - keeping it"
else
  tmp=$(mktemp -d /dev/shm/jenkins.XXXXXX)          # RAM-backed, removed below
  trap 'rm -rf "$tmp"' EXIT
  ssh-keygen -q -t ed25519 -N '' -C "jenkins-deploy@qwenops" -f "$tmp/key"
  kubectl -n ci create secret generic jenkins-secrets \
    --from-literal=admin-password="$(openssl rand -base64 24 | tr -d '/+=')" \
    --from-file=github-deploy-key="$tmp/key" \
    --from-file=github-deploy-key.pub="$tmp/key.pub" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -rf "$tmp"
fi

# Added in Phase 8: the Pipeline page's read-and-start-only Jenkins account. Added to an existing secret too.
if ! kubectl -n ci get secret jenkins-secrets -o jsonpath='{.data.pipeline-viewer-password}' | grep -q .; then
  kubectl -n ci patch secret jenkins-secrets --type merge \
    -p "{\"stringData\":{\"pipeline-viewer-password\":\"$(openssl rand -base64 24 | tr -d '/+=')\"}}" >/dev/null
  echo "pipeline-viewer password generated"
fi

kubectl -n ci create configmap jenkins-settings \
  --from-literal=GIT_REPO_URL="$REPO_URL" --from-literal=GIT_BRANCH="$GIT_BRANCH" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> controller"
CONFIG_HASH=$( { cat k8s/ci/20-jenkins.yaml; echo "$REPO_URL $GIT_BRANCH"; } | sha256sum | cut -c1-12)
sed -e "s|__JENKINS_IMAGE__|$IMAGE|" -e "s|__CONFIG_HASH__|$CONFIG_HASH|" k8s/ci/20-jenkins.yaml | kubectl apply -f -
kubectl -n ci rollout status deployment/jenkins --timeout=600s

# A job that config-as-code creates for the first time is written to disk, but Jenkins then loads the jobs
# from disk a moment later and the new one is missing until a reload (seen with theme-deploy). Check each job
# as admin from inside the pod (the password never leaves it) and reload from disk if one is missing.
echo "==> jobs"
for i in $(seq 30); do kubectl -n ci exec deploy/jenkins -- curl -sf -o /dev/null http://localhost:8080/login && break; sleep 5; done
kubectl -n ci exec deploy/jenkins -- sh -c '
  J=http://localhost:8080; A="admin:$(cat /run/secrets/admin-password)"
  missing=""
  for job in chatbot theme-deploy; do
    [ "$(curl -s -o /dev/null -w "%{http_code}" -u "$A" "$J/job/$job/api/json")" = 200 ] || missing="$missing $job"
  done
  if [ -n "$missing" ]; then
    echo "   missing:$missing -> reloading the configuration from disk"
    crumb=$(curl -s -c /tmp/jar -u "$A" "$J/crumbIssuer/api/json" | sed -n "s/.*\"crumb\":\"\([^\"]*\)\".*\"crumbRequestField\":\"\([^\"]*\)\".*/\2: \1/p")
    curl -s -o /dev/null -b /tmp/jar -u "$A" -H "$crumb" -X POST "$J/reload"; rm -f /tmp/jar
    sleep 15
  fi
  for job in chatbot theme-deploy; do
    printf "   %-14s %s\n" "$job" "$(curl -s -o /dev/null -w "%{http_code}" -u "$A" "$J/job/$job/api/json")"
  done'

echo "==> pipeline-events (Pipeline page and \"Be a Dev\")"
kubectl -n ci create configmap pipeline-events-code --from-file=ci/pipeline-events/pipeline_events.py \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f k8s/ci/30-pipeline-events.yaml
kubectl -n ci rollout restart deployment/pipeline-events >/dev/null
kubectl -n ci rollout status deployment/pipeline-events --timeout=120s
kubectl -n ci wait certificate/jenkins-tls --for=condition=Ready --timeout=120s

cat <<MSG

Jenkins is up: https://jenkins.chatbot.local  (user: admin, password: make jenkins-password)
Other devices find jenkins.chatbot.local through the Raspberry Pi gateway (make pi-gateway).

1) Add this READ-ONLY deploy key to GitHub (repo > Settings > Deploy keys > Add, leave "Allow write" off):

$(kubectl -n ci get secret jenkins-secrets -o jsonpath='{.data.github-deploy-key\.pub}' | base64 -d)

2) Connect the build agent on this host:  make jenkins-agent
MSG
