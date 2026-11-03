#!/usr/bin/env bash
# Namespaces (PSA restricted), quotas, default-deny network policies, then shared Ollama + Postgres.
set -euo pipefail
cd "$(dirname "$0")/.."

kubectl apply -f k8s/platform/00-namespaces.yaml
kubectl apply -f k8s/platform/10-quotas.yaml -f k8s/platform/20-default-deny.yaml

./scripts/05-secrets.sh

kubectl apply -f k8s/platform/30-ollama.yaml -f k8s/platform/40-postgres.yaml -f k8s/platform/50-prometheus.yaml
# Config changes aren't picked up live; restart so a re-run always applies the latest scrape config.
kubectl -n monitoring rollout restart deployment/prometheus >/dev/null
echo "==> waiting for Postgres"
kubectl -n data rollout status statefulset/postgres --timeout=180s
echo "==> waiting for Prometheus (Pulse page)"
kubectl -n monitoring rollout status deployment/prometheus --timeout=180s
echo "==> waiting for Ollama (first run downloads the model, a few minutes)"
kubectl -n ai rollout status deployment/ollama --timeout=900s
echo "Platform ready. Next: ./scripts/03-build-push.sh then ./scripts/06-deploy.sh dev"
