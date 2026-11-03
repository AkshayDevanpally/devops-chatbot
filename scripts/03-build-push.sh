#!/usr/bin/env bash
# Build once, tag with the Git SHA, scan, push. The same tag is then promoted dev -> qa -> prod.
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-localhost:5000}"
TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then TAG="${TAG}-dirty"; fi

declare -A CONTEXT=([chat-api]=app-chat [ui]=app-ui)
for svc in chat-api ui; do
  ctx="${CONTEXT[$svc]}"
  echo "==> build $svc:$TAG"
  DOCKER_BUILDKIT=1 docker build --pull --build-arg GIT_SHA="$TAG" -t "$REGISTRY/$svc:$TAG" "$ctx"

  if command -v hadolint >/dev/null; then hadolint "$ctx/Dockerfile"; fi
  if command -v trivy >/dev/null; then
    echo "==> scan $svc (fails on HIGH/CRITICAL with a fix available)"
    trivy image --quiet --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 "$REGISTRY/$svc:$TAG"
  else
    echo "!! trivy not installed - skipping scan (install it: https://trivy.dev)"
  fi
  docker push "$REGISTRY/$svc:$TAG"
done

echo "$TAG" > .last-tag
echo "Pushed tag $TAG. Next: ./scripts/06-deploy.sh dev"
