#!/usr/bin/env bash
# Usage: ./scripts/06-deploy.sh <dev|qa|prod> [tag]
# Deploys an already-built tag. --atomic rolls back automatically if the rollout fails.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV="${1:?usage: $0 <dev|qa|prod> [tag]}"
[[ $ENV =~ ^(dev|qa|prod)$ ]] || { echo "env must be dev, qa or prod"; exit 1; }
TAG="${2:-$(cat .last-tag 2>/dev/null || true)}"
[[ -n $TAG ]] || { echo "no tag: run ./scripts/03-build-push.sh first"; exit 1; }

# Jenkins sets PROD_APPROVED=yes only after someone approves the "Ship to prod" stage.
if [[ $ENV == prod && ${PROD_APPROVED:-} != yes ]]; then
  read -r -p "Deploy $TAG to PROD? type 'yes': " ok
  [[ $ok == yes ]] || { echo "aborted"; exit 1; }
fi

helm lint helm/chatbot -f "helm/chatbot/values-$ENV.yaml" --set image.tag="$TAG"
helm upgrade --install "chatbot-$ENV" helm/chatbot \
  --namespace "chatbot-$ENV" \
  -f "helm/chatbot/values-$ENV.yaml" \
  --set image.tag="$TAG" \
  --atomic --wait --timeout 5m

kubectl -n "chatbot-$ENV" get pods -o wide
HOST=$(helm get values "chatbot-$ENV" -n "chatbot-$ENV" --all -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["host"])')
echo "Deployed $TAG to $ENV -> https://$HOST"
