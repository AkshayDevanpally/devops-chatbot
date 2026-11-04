#!/usr/bin/env bash
# Phase 3.4: HTTPS for all environments.
# cert-manager + a private local CA, then Traefik redirects HTTP -> HTTPS.
# Re-runnable. Afterwards: re-deploy each env (make deploy-dev ...) and trust the CA (make trust-ca).
set -euo pipefail
cd "$(dirname "$0")/.."

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.3}"
CA_OUT=certs/chatbot-local-ca.crt

echo "==> cert-manager namespace + network policies"
kubectl apply -f k8s/tls/00-namespace.yaml -f k8s/tls/10-network-policy.yaml

echo "==> cert-manager $CERT_MANAGER_VERSION"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version "$CERT_MANAGER_VERSION" \
  -f k8s/tls/cert-manager-values.yaml \
  --wait --timeout 5m

echo "==> local CA"
kubectl apply -f k8s/tls/20-local-ca.yaml
kubectl -n cert-manager wait certificate/chatbot-local-ca --for=condition=Ready --timeout=120s
kubectl wait clusterissuer/chatbot-local-ca --for=condition=Ready --timeout=60s

echo "==> Traefik: redirect HTTP to HTTPS"
kubectl apply -f k8s/tls/30-traefik-https.yaml

echo "==> exporting the CA certificate (public part only) to $CA_OUT"
mkdir -p certs
kubectl -n cert-manager get secret chatbot-local-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA_OUT"
openssl x509 -in "$CA_OUT" -noout -subject -enddate -fingerprint -sha256

cat <<MSG

TLS ready. Next:
  make deploy-dev && make deploy-qa && make deploy-prod   # adds certificates to each Ingress
  make trust-ca                                           # trust the CA on this machine
Other devices: copy $CA_OUT and import it (see README, "HTTPS").
MSG
