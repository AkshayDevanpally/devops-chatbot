#!/usr/bin/env bash
# Proves the deployment works AND that the security controls actually block things.
# Usage: ./scripts/07-verify.sh [dev|qa|prod]
set -uo pipefail
ENV="${1:-dev}"; NS="chatbot-$ENV"
case $ENV in prod) HOST=chatbot.local ;; *) HOST="$ENV.chatbot.local" ;; esac
pass=0; fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"; ((pass++)); else echo "FAIL  $1"; ((fail++)); fi; }
blocked() { if eval "$2" >/dev/null 2>&1; then echo "FAIL  $1 (was allowed)"; ((fail++)); else echo "PASS  $1"; ((pass++)); fi; }

echo "== functional ($HOST) =="
check "UI serves the page"            "curl -sf http://$HOST/ | grep -q 'Qwen Chat'"
check "API liveness"                  "curl -sf http://$HOST/api/healthz"
check "API ready (db + model reachable)" "curl -sf http://$HOST/api/readyz"
check "model is loaded"               "curl -sf http://$HOST/api/status | grep -q '\"ready\"'"
blocked "metrics not exposed publicly"     "curl -sf http://$HOST/api/metrics"
check "security headers on UI"        "curl -sI http://$HOST/ | grep -qi content-security-policy"
check "bad theme colour rejected"     "test \$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{\"color\":\"<script>\"}' http://$HOST/api/theme) = 422"
check "Pulse page served"             "curl -sf http://$HOST/pulse/ | grep -q '<title>Pulse'"
check "Pulse has live Prometheus data" "curl -sf http://$HOST/api/pulse | grep -q '\"available\":true'"
check "Pulse rejects unknown ranges"  "test \$(curl -s -o /dev/null -w '%{http_code}' 'http://$HOST/api/pulse?range=30d') = 422"

echo "== Pod Security Admission =="
blocked "privileged pod rejected in $NS" \
  "kubectl -n $NS run psa-test --image=busybox:1.36 --restart=Never --overrides='{\"spec\":{\"containers\":[{\"name\":\"t\",\"image\":\"busybox:1.36\",\"securityContext\":{\"privileged\":true}}]}}' --dry-run=server"

echo "== NetworkPolicy =="
SAFE='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"t","image":"busybox:1.36","command":["sh","-c","nc -z -w 3 $TARGET"],"env":[{"name":"TARGET","value":"__T__"}],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"resources":{"limits":{"cpu":"50m","memory":"32Mi"}}}]}}'
nettest() { # $1=namespace $2="host port"
  kubectl -n "$1" delete pod nettest --ignore-not-found >/dev/null 2>&1
  kubectl -n "$1" run nettest --image=busybox:1.36 --restart=Never --overrides="${SAFE/__T__/$2}" >/dev/null 2>&1 || return 1
  kubectl -n "$1" wait --for=jsonpath='{.status.phase}'=Succeeded pod/nettest --timeout=30s >/dev/null 2>&1; rc=$?
  kubectl -n "$1" delete pod nettest --ignore-not-found >/dev/null 2>&1; return $rc
}
blocked "random pod in $NS cannot reach Postgres"  "nettest $NS 'postgres.data.svc.cluster.local 5432'"
blocked "random pod in $NS cannot reach Ollama"    "nettest $NS 'ollama.ai.svc.cluster.local 11434'"
blocked "random pod in $NS cannot reach the internet" "nettest $NS 'example.com 443'"
blocked "random pod in $NS cannot reach Prometheus" "nettest $NS 'prometheus.monitoring.svc.cluster.local 9090'"

echo "== RBAC / service accounts =="
check "chat-api has no API token mounted" \
  "test -z \"\$(kubectl -n $NS get pod -l app.kubernetes.io/component=api -o jsonpath='{.items[0].spec.containers[0].volumeMounts[*].mountPath}' | grep serviceaccount)\""

echo; echo "passed: $pass   failed: $fail"
[[ $fail -eq 0 ]]
