#!/usr/bin/env bash
# Proves the deployment works AND that the security controls actually block things.
# Usage: ./scripts/07-verify.sh [dev|qa|prod]
set -uo pipefail
ENV="${1:-dev}"; NS="chatbot-$ENV"
case $ENV in prod) HOST=chatbot.local ;; *) HOST="$ENV.chatbot.local" ;; esac
pass=0; fail=0
# HTTPS against the local CA (make tls). --resolve so it works without /etc/hosts entries.
# CA_FILE: set by the Jenkins agent (the repo's certs/ folder is git-ignored, so a clean checkout lacks it).
CA="${CA_FILE:-$(dirname "$0")/../certs/chatbot-local-ca.crt}"
URL="https://$HOST"
curl() { command curl --cacert "$CA" --resolve "$HOST:443:127.0.0.1" --resolve "$HOST:80:127.0.0.1" "$@"; }
[[ -s $CA ]] || { echo "missing $CA: run make tls first"; exit 1; }
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"; ((pass++)); else echo "FAIL  $1"; ((fail++)); fi; }
blocked() { if eval "$2" >/dev/null 2>&1; then echo "FAIL  $1 (was allowed)"; ((fail++)); else echo "PASS  $1"; ((pass++)); fi; }

echo "== waiting for $HOST to answer steadily (up to 60 s) =="
# Right after a rollout, the newest pods may not be reachable yet (policy-engine delay). Wait for
# five good answers in a row before testing, so checks measure the app and not the rollout.
ok=0
for _ in $(seq 1 30); do
  if curl -sf "$URL/api/status" 2>/dev/null | grep '"ready"' >/dev/null && curl -sf "$URL/" >/dev/null 2>&1; then
    ok=$((ok + 1)); [[ $ok -ge 5 ]] && break
  else
    ok=0
  fi
  sleep 2
done
echo "steady after $ok good answers in a row"

echo "== functional ($HOST) =="
check "UI serves the page"            "curl -sf $URL/ | grep -q 'Qwen Chat'"
check "API liveness"                  "curl -sf $URL/api/healthz"
check "API ready (db + model reachable)" "curl -sf $URL/api/readyz"
check "model is loaded"               "curl -sf $URL/api/status | grep -q '\"ready\"'"
blocked "metrics not exposed publicly"     "curl -sf $URL/api/metrics"
check "security headers on UI"        "curl -sI $URL/ | grep -qi content-security-policy"
check "bad theme colour rejected"     "test \$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{\"color\":\"<script>\"}' $URL/api/theme) = 422"
check "Pulse page served"             "curl -sf $URL/pulse/ | grep -q '<title>Pulse'"
check "Architecture page served"      "curl -sf $URL/architecture/ | grep -q '<title>Architecture'"
check "Pulse has live Prometheus data" "curl -sf $URL/api/pulse | grep -q '\"available\":true'"
check "Capacity page has live data"   "curl -sf $URL/api/capacity | grep -q '\"available\":true'"
# grep without -q reads the whole body: with pipefail, -q quitting early would make curl fail (SIGPIPE)
check "Journal built from docs/"       "curl -sf $URL/journal/journal.json | grep '\"entries\"' >/dev/null"
check "Pulse rejects unknown ranges"  "test \$(curl -s -o /dev/null -w '%{http_code}' '$URL/api/pulse?range=30d') = 422"

echo "== TLS =="
check "certificate is Ready"          "kubectl -n $NS wait certificate/chatbot-tls --for=condition=Ready --timeout=5s"
check "cert valid for $HOST, signed by local CA" "curl -sf -o /dev/null $URL/"
check "plain HTTP redirects to HTTPS" "curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://$HOST/ | grep -Eq '^30[178] https://$HOST/'"
check "HSTS header sent"              "curl -sI $URL/ | grep -qi strict-transport-security"
check "identity cookie is Secure + HttpOnly" "curl -s -D - -o /dev/null $URL/api/history | grep -i '^set-cookie: uid=' | grep -i secure | grep -qi httponly"
blocked "TLS 1.1 refused"             "command curl -s -o /dev/null --cacert $CA --resolve $HOST:443:127.0.0.1 --tlsv1.1 --tls-max 1.1 $URL/"

echo "== Pod Security Admission =="
blocked "privileged pod rejected in $NS" \
  "kubectl -n $NS run psa-test --image=busybox:1.36 --restart=Never --overrides='{\"spec\":{\"containers\":[{\"name\":\"t\",\"image\":\"busybox:1.36\",\"securityContext\":{\"privileged\":true}}]}}' --dry-run=server"

echo "== NetworkPolicy =="
# One probe pod tests every target (four pods would also exceed dev/qa's 5-pod quota). It waits
# 10 s first: k3s's policy engine (kube-router) applies egress rules a few seconds after a pod
# starts, and connecting inside that window gives a false "allowed". It prints one line per
# target: "<host> <port> open|closed".
TARGETS="postgres.data.svc.cluster.local:5432 ollama.ai.svc.cluster.local:11434 example.com:443 prometheus.monitoring.svc.cluster.local:9090"
PROBE='sleep 10; for t in $TARGETS; do h=${t%:*}; p=${t##*:}; if nc -z -w 3 $h $p; then echo "$h $p open"; else echo "$h $p closed"; fi; done'
SAFE=$(python3 -c 'import json,sys; print(json.dumps({"spec":{"securityContext":{"runAsNonRoot":True,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"t","image":"busybox:1.36","command":["sh","-c",sys.argv[1]],"env":[{"name":"TARGETS","value":sys.argv[2]}],"securityContext":{"allowPrivilegeEscalation":False,"capabilities":{"drop":["ALL"]}},"resources":{"limits":{"cpu":"50m","memory":"32Mi"}}}]}}))' "$PROBE" "$TARGETS")
kubectl -n "$NS" delete pod nettest --ignore-not-found >/dev/null 2>&1
PROBES=""
if kubectl -n "$NS" run nettest --image=busybox:1.36 --restart=Never --overrides="$SAFE" >/dev/null 2>&1 \
   && kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/nettest --timeout=60s >/dev/null 2>&1; then
  PROBES=$(kubectl -n "$NS" logs nettest 2>/dev/null)
fi
kubectl -n "$NS" delete pod nettest --ignore-not-found >/dev/null 2>&1
# "blocked" only if the probe ran and reported the target closed; no result counts as a failure.
closed() { grep -q "^$1 closed$" <<<"$PROBES"; }
check "random pod in $NS cannot reach Postgres"       "closed 'postgres.data.svc.cluster.local 5432'"
check "random pod in $NS cannot reach Ollama"         "closed 'ollama.ai.svc.cluster.local 11434'"
check "random pod in $NS cannot reach the internet"   "closed 'example.com 443'"
check "random pod in $NS cannot reach Prometheus"     "closed 'prometheus.monitoring.svc.cluster.local 9090'"

echo "== RBAC / service accounts =="
check "chat-api has no API token mounted" \
  "test -z \"\$(kubectl -n $NS get pod -l app.kubernetes.io/component=api -o jsonpath='{.items[0].spec.containers[0].volumeMounts[*].mountPath}' | grep serviceaccount)\""

echo; echo "passed: $pass   failed: $fail"
[[ $fail -eq 0 ]]
