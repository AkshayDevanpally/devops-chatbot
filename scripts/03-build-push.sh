#!/usr/bin/env bash
# Build once, tag with the Git SHA, scan, push. The same tag is then promoted dev -> qa -> prod.
# Usage: ./scripts/03-build-push.sh [all|build|scan|sbom|push]
#   all (default, = make build): build + lint + scan + push
#   build / scan / sbom / push: single steps, used by the Jenkinsfile so each shows as its own stage.
set -euo pipefail
cd "$(dirname "$0")/.."

STEP="${1:-all}"
[[ $STEP =~ ^(all|build|scan|sbom|push)$ ]] || { echo "usage: $0 [all|build|scan|sbom|push]"; exit 1; }
REGISTRY="${REGISTRY:-localhost:5000}"
if [[ -z "${TAG:-}" ]]; then
  TAG="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then TAG="${TAG}-dirty"; fi
fi

declare -A CONTEXT=([chat-api]=app-chat [ui]=app-ui)

build() {
  echo "==> build $1:$TAG"
  local extra=()
  # The UI image also reads docs/ (Journal page), as a second, named build context.
  [[ $1 == ui ]] && extra=(--build-context docs=docs)
  DOCKER_BUILDKIT=1 docker build --pull "${extra[@]}" --build-arg GIT_SHA="$TAG" -t "$REGISTRY/$1:$TAG" "${CONTEXT[$1]}"
  if command -v hadolint >/dev/null; then hadolint "${CONTEXT[$1]}/Dockerfile"; fi
}
scan() {
  if command -v trivy >/dev/null; then
    echo "==> scan $1:$TAG (fails on HIGH/CRITICAL with a fix available)"
    trivy image --quiet --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 "$REGISTRY/$1:$TAG"
  elif [[ -n "${CI:-}" ]]; then
    echo "!! trivy not installed - a pipeline must not skip the scan"; exit 1
  else
    echo "!! trivy not installed - skipping scan (install it: https://trivy.dev)"
  fi
}
sbom() {   # software bill of materials: every package in the image, kept with the build
  mkdir -p sbom
  trivy image --quiet --format spdx-json --output "sbom/$1-$TAG.spdx.json" "$REGISTRY/$1:$TAG"
  echo "==> sbom/$1-$TAG.spdx.json"
}
push() { docker push "$REGISTRY/$1:$TAG"; }

for svc in chat-api ui; do
  case $STEP in
    all) build "$svc"; scan "$svc"; push "$svc" ;;
    *) "$STEP" "$svc" ;;
  esac
done

if [[ $STEP == all || $STEP == push ]]; then
  echo "$TAG" > .last-tag
  echo "Pushed tag $TAG. Next: ./scripts/06-deploy.sh dev"
fi
