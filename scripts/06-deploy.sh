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

# Phase 6: prod keeps its burst pods while an AWS burst node is Ready and its Ollama exists.
# BURST=off forces them off (scripts/13-burst.sh down).
BURST_ON=false
if [[ $ENV == prod && ${BURST:-auto} != off ]] \
   && kubectl get nodes -l qwenops.io/burst=true \
        -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -qx True \
   && kubectl -n ai get deployment ollama-burst >/dev/null 2>&1; then
  BURST_ON=true
  echo "==> AWS burst node is up: deploying chat-api-burst too"
fi

# Each env keeps the colour chosen on its "Be a Dev" page (scripts/19-theme.sh), not values-<env>.yaml's.
THEME_ARGS=()
chosen=$(kubectl -n "chatbot-$ENV" get configmap chatbot-theme -o jsonpath='{.data.color}' 2>/dev/null || true)
if [[ $chosen =~ ^(teal|indigo|rose|amber|emerald|slate)$ ]]; then
  THEME_ARGS=(--set theme="$chosen"); echo "==> $ENV keeps its chosen colour: $chosen"
fi

# --set-string: a commit id can be all digits (5151604). With --set Helm stores it as a number, and a later
# --reuse-values upgrade (Be a Dev) renders it as 5.151604e+06, which isn't a valid label (Issue 49).
helm lint helm/chatbot -f "helm/chatbot/values-$ENV.yaml" --set-string image.tag="$TAG"
helm upgrade --install "chatbot-$ENV" helm/chatbot \
  --namespace "chatbot-$ENV" \
  -f "helm/chatbot/values-$ENV.yaml" \
  --set-string image.tag="$TAG" \
  --set burst.enabled="$BURST_ON" "${THEME_ARGS[@]}" \
  --atomic --wait --timeout 5m

kubectl -n "chatbot-$ENV" get pods -o wide
HOST=$(helm get values "chatbot-$ENV" -n "chatbot-$ENV" --all -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["host"])')
echo "Deployed $TAG to $ENV -> https://$HOST"
