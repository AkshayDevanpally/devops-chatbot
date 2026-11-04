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

kubectl -n ci create configmap jenkins-settings \
  --from-literal=GIT_REPO_URL="$REPO_URL" --from-literal=GIT_BRANCH="$GIT_BRANCH" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> controller"
CONFIG_HASH=$( { cat k8s/ci/20-jenkins.yaml; echo "$REPO_URL $GIT_BRANCH"; } | sha256sum | cut -c1-12)
sed -e "s|__JENKINS_IMAGE__|$IMAGE|" -e "s|__CONFIG_HASH__|$CONFIG_HASH|" k8s/ci/20-jenkins.yaml | kubectl apply -f -
kubectl -n ci rollout status deployment/jenkins --timeout=600s
kubectl -n ci wait certificate/jenkins-tls --for=condition=Ready --timeout=120s

cat <<MSG

Jenkins is up: https://jenkins.chatbot.local  (user: admin, password: make jenkins-password)
Add jenkins.chatbot.local to the hosts file of any PC you open it from.

1) Add this READ-ONLY deploy key to GitHub (repo > Settings > Deploy keys > Add, leave "Allow write" off):

$(kubectl -n ci get secret jenkins-secrets -o jsonpath='{.data.github-deploy-key\.pub}' | base64 -d)

2) Connect the build agent on this host:  make jenkins-agent
MSG
