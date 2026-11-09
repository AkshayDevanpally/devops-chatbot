#!/usr/bin/env bash
# Phase 5 (home side): TLS for Postgres from the local CA, then check it.
# Needs cert-manager and the local CA first (make tls). Re-runnable.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=data

kubectl wait clusterissuer/chatbot-local-ca --for=condition=Ready --timeout=30s >/dev/null \
  || { echo "local CA not ready: run 'make tls' first"; exit 1; }

echo "==> Postgres certificate"
kubectl apply -f k8s/tunnel/10-postgres-tls.yaml
kubectl -n $NS wait certificate/postgres-tls --for=condition=Ready --timeout=120s

echo "==> Postgres (pg_hba.conf, tunnel Service, network policy, TLS)"
kubectl apply -f k8s/platform/40-postgres.yaml
# TLS is switched on at startup, so restart once if the running server doesn't have it yet.
if [ "$(kubectl -n $NS exec postgres-0 -c postgres -- psql -U postgres -Atc 'show ssl' 2>/dev/null)" != on ]; then
  kubectl -n $NS rollout restart statefulset/postgres
fi
kubectl -n $NS rollout status statefulset/postgres --timeout=180s
i=0; until kubectl -n $NS exec postgres-0 -c postgres -- pg_isready -q 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 30 ] || { echo "Postgres not ready"; exit 1; }; sleep 2
done

echo "==> checks"
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got '$2', want '$3')"; fail=1; fi; }
pg() { kubectl -n $NS exec postgres-0 -c postgres -- sh -c "$1" 2>&1 || true; }

# Probe pod for a real network connection: Postgres's own pod may not open connections (default-deny
# egress), so borrow the backup job's label, which may reach Postgres on 5432 and nothing else.
probe() {
  kubectl -n $NS delete pod tls-probe --ignore-not-found --wait=true >/dev/null
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: tls-probe, namespace: $NS, labels: { app.kubernetes.io/name: postgres-backup } }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 70
    runAsGroup: 70
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: probe
      image: postgres:16-alpine
      command: ["/bin/sh", "-c"]
      args:
        - |
          # k3s applies network rules a few seconds after a pod starts.
          i=0; until pg_isready -q -h postgres.data.svc.cluster.local; do i=\$((i+1)); [ \$i -lt 15 ] || break; sleep 2; done
          psql -Atc "select ssl, version from pg_stat_ssl where pid = pg_backend_pid()" \\
            "host=postgres.data.svc.cluster.local dbname=postgres user=postgres sslmode=verify-full sslrootcert=/tls/ca.crt"
      env:
        - name: PGPASSWORD
          valueFrom: { secretKeyRef: { name: postgres-secrets, key: POSTGRES_PASSWORD } }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: [ALL] }
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { cpu: 100m, memory: 64Mi }
      volumeMounts: [{ name: tls, mountPath: /tls, readOnly: true }]
  volumes:
    - { name: tls, secret: { secretName: postgres-tls, items: [{ key: ca.crt, path: ca.crt }] } }
YAML
  kubectl -n $NS wait pod/tls-probe --for=jsonpath='{.status.phase}'=Succeeded --timeout=90s >/dev/null 2>&1 || true
  kubectl -n $NS logs tls-probe 2>&1 | tail -1
  kubectl -n $NS delete pod tls-probe --wait=false >/dev/null
}

check "TLS on" "$(pg "psql -U postgres -Atc 'show ssl'")" on
check "pg_hba.conf has no errors" "$(pg "psql -U postgres -Atc 'select count(*) from pg_hba_file_rules where error is not null'")" 0
check "verify-full by Service name, against the local CA (TLS 1.3)" "$(probe)" "t|TLSv1.3"
check "app connections use TLS" "$(pg "psql -U postgres -Atc \"select count(*) from pg_stat_activity a join pg_stat_ssl s using (pid) where a.usename like 'chat_%' and not s.ssl\"")" 0
# The certificate must also be valid for the tunnel address.
got=$(kubectl -n $NS get secret postgres-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -ext subjectAltName | grep -o 'IP Address:10.200.0.1' || true)
check "certificate covers tunnel address" "$got" "IP Address:10.200.0.1"
check "tunnel Service bound to 10.200.0.1" \
  "$(kubectl -n $NS get svc postgres-tunnel -o jsonpath='{.spec.externalIPs[0]}')" 10.200.0.1

# App pods reconnect after the restart.
for env in dev qa prod; do
  kubectl -n "chatbot-$env" rollout status deployment/chat-api --timeout=120s >/dev/null 2>&1 || true
  ready=$(kubectl -n "chatbot-$env" get deploy chat-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  want=$(kubectl -n "chatbot-$env" get deploy chat-api -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  check "chat-api $env ready" "${ready:-0}" "$want"
done

mkdir -p certs
kubectl -n $NS get secret postgres-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > certs/postgres-ca.crt
echo "CA for Postgres clients (sslrootcert): certs/postgres-ca.crt"
exit "$fail"
