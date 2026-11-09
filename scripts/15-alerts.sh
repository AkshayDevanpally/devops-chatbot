#!/usr/bin/env bash
# Alerts to your phone through ntfy (k8s/platform/55-alerting.yaml; rules in 50-prometheus.yaml).
#
#   ./scripts/15-alerts.sh topic [--new]   # show (or make) the private ntfy topic to subscribe to
#   ./scripts/15-alerts.sh install         # Alertmanager, ntfy-bridge, rules; backup health metrics
#   ./scripts/15-alerts.sh test            # send a test alert through the whole chain
#   ./scripts/15-alerts.sh status          # rules loaded, alerts firing now, bridge log
set -euo pipefail
cd "$(dirname "$0")/.."
NS=monitoring

topic() {
  if [[ ${1:-} != --new ]] && kubectl -n $NS get secret ntfy >/dev/null 2>&1; then
    t=$(kubectl -n $NS get secret ntfy -o jsonpath='{.data.NTFY_TOPIC}' | base64 -d)
  else
    # On ntfy.sh anyone who knows a topic name can read it, so it must be unguessable.
    t="qwenops-$(openssl rand -hex 12)"
    kubectl -n $NS create secret generic ntfy --from-literal=NTFY_TOPIC="$t" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n $NS rollout restart deployment/ntfy-bridge >/dev/null 2>&1 || true
    echo "New topic saved (secret ntfy in namespace $NS)."
  fi
  cat <<MSG

Subscribe on your phone:
  1. Install the "ntfy" app (Android: Play Store / F-Droid, iPhone: App Store).
  2. Tap +  -> topic name:  $t   (server: ntfy.sh, the default)
Or in a browser: https://ntfy.sh/$t
Keep the topic name private: anyone who has it can read your alerts. New name: make alerts-topic NEW=1
MSG
}

install() {
  echo "==> monitoring quota (room for Alertmanager and ntfy-bridge)"
  python3 -I -c '
docs = open("k8s/platform/10-quotas.yaml").read().split("\n---\n")
q = [d for d in docs if "kind: ResourceQuota" in d and "namespace: monitoring" in d]
assert len(q) == 1, "monitoring quota not found"
print(q[0])' | kubectl apply -f -
  echo "==> ntfy-bridge code, Alertmanager, network rules"
  kubectl -n $NS create configmap ntfy-bridge-code --from-file=k8s/platform/ntfy-bridge/ntfy_bridge.py \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f k8s/platform/55-alerting.yaml
  echo "==> Prometheus: alert rules, Alertmanager, backup-ops scrape"
  kubectl apply -f k8s/platform/50-prometheus.yaml
  echo "==> backup-ops: health metrics for the backup alerts"
  ./scripts/10-backups.sh install >/dev/null
  for d in prometheus alertmanager ntfy-bridge; do kubectl -n $NS rollout restart deployment/$d >/dev/null; done
  for d in prometheus alertmanager ntfy-bridge; do kubectl -n $NS rollout status deployment/$d --timeout=180s; done
  kubectl -n $NS get secret ntfy >/dev/null 2>&1 || echo "No ntfy topic yet: make alerts-topic"
  echo "Installed. Send a test: make alerts-test"
}

test_alert() {
  kubectl -n $NS get secret ntfy >/dev/null 2>&1 || { echo "no topic yet: make alerts-topic"; exit 1; }
  end=$(date -u -d '+5 min' +%Y-%m-%dT%H:%M:%SZ)
  kubectl -n $NS exec deploy/alertmanager -- amtool alert add QwenOpsTest severity=info \
    --annotation='summary="Test alert from QwenOps: alerts reach your phone"' \
    --annotation='description="Nothing to do. A Resolved message follows in about 10 minutes."' \
    --end="$end" --alertmanager.url=http://localhost:9093
  echo "Test alert sent to Alertmanager. It waits 30 s to group alerts, then your phone should buzz."
  for _ in $(seq 20); do
    line=$(kubectl -n $NS logs deploy/ntfy-bridge --since=2m | grep QwenOpsTest | tail -1 || true)
    [ -n "$line" ] && { echo "bridge: $line"; return; }
    sleep 3
  done
  echo "No send logged yet: make alerts-status"
}

status() {
  echo "==> rules and Alertmanager as Prometheus sees them"
  kubectl -n $NS exec deploy/prometheus -- wget -qO- http://localhost:9090/api/v1/rules | python3 -c '
import json, sys
groups = json.load(sys.stdin)["data"]["groups"]
rules = [r for g in groups for r in g["rules"]]
bad = [r["name"] for r in rules if r.get("health") != "ok"]
print(f"{len(rules)} rules loaded" + (f", unhealthy: {bad}" if bad else ", all healthy"))
for r in rules:
    if r.get("state") in ("pending", "firing"):
        state, name = r["state"].upper(), r["name"]
        print(f"  {state:8} {name}")'
  kubectl -n $NS exec deploy/prometheus -- wget -qO- http://localhost:9090/api/v1/alertmanagers | python3 -c '
import json, sys; a = json.load(sys.stdin)["data"]["activeAlertmanagers"]; print("Alertmanagers connected:", len(a))'
  echo "==> alerts in Alertmanager"
  kubectl -n $NS exec deploy/alertmanager -- amtool alert query --alertmanager.url=http://localhost:9093 || true
  echo "==> ntfy-bridge (last sends)"
  kubectl -n $NS logs deploy/ntfy-bridge --tail=5 || true
}

case "${1:-}" in
  topic) topic "${2:-}" ;; install) install ;; test) test_alert ;; status) status ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
