#!/usr/bin/env bash
# Generates strong random secrets straight into the cluster. Nothing is written to disk or Git.
# Existing secrets are left untouched, so this is safe to re-run.
# (Phase 9 replaces this with External Secrets Operator + AWS Secrets Manager.)
set -euo pipefail

rand() { openssl rand -hex 32; }
exists() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }

if exists data postgres-secrets; then
  echo "postgres-secrets exists - keeping it"
else
  echo "==> creating postgres-secrets"
  kubectl -n data create secret generic postgres-secrets \
    --from-literal=POSTGRES_PASSWORD="$(rand)" \
    --from-literal=CHAT_DEV_PASSWORD="$(rand)" \
    --from-literal=CHAT_QA_PASSWORD="$(rand)" \
    --from-literal=CHAT_PROD_PASSWORD="$(rand)" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

for env in dev qa prod; do
  ns="chatbot-$env"
  if exists "$ns" chat-api-secrets; then
    echo "chat-api-secrets in $ns exists - keeping it"
    continue
  fi
  key="CHAT_$(echo "$env" | tr a-z A-Z)_PASSWORD"
  pw=$(kubectl -n data get secret postgres-secrets -o "jsonpath={.data.$key}" | base64 -d)
  echo "==> creating chat-api-secrets in $ns"
  kubectl -n "$ns" create secret generic chat-api-secrets \
    --from-literal=DATABASE_URL="postgresql://chat_${env}:${pw}@postgres.data.svc.cluster.local:5432/chat_${env}" \
    --from-literal=SESSION_SECRET="$(rand)" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
