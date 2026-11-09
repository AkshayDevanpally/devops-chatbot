#!/usr/bin/env bash
# "Be a Dev" colour deploys to dev (ci/theme-deploy.Jenkinsfile, started from the site).
#
#   ./scripts/19-theme.sh validate COLOR   # only the six allowed colours
#   ./scripts/19-theme.sh deploy COLOR     # remember it, then roll dev's UI with the new colour
#   ./scripts/19-theme.sh verify COLOR     # dev serves it (theme.json over HTTPS, checked against the home CA)
#   ./scripts/19-theme.sh show             # dev's current colour
#
# The colour is kept in ConfigMap chatbot-theme (namespace chatbot-dev), so a normal pipeline deploy
# (scripts/06-deploy.sh) keeps it instead of resetting dev to helm/chatbot/values-dev.yaml.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=chatbot-dev
ALLOWED="teal indigo rose amber emerald slate"
CMD="${1:-}"; COLOR="${2:-}"

valid() { [[ " $ALLOWED " == *" $COLOR "* ]] || { echo "colour must be one of: $ALLOWED (got '$COLOR')"; exit 1; }; }

case "$CMD" in
  validate)
    valid; echo "colour '$COLOR' is allowed" ;;
  deploy)
    valid
    before=$(kubectl -n $NS get configmap ui-theme -o jsonpath='{.data.theme\.json}' 2>/dev/null || echo "?")
    echo "dev now: $before"
    kubectl -n $NS create configmap chatbot-theme --from-literal=color="$COLOR" \
      --from-literal=requested-at="$(date -u +%FT%TZ)" --from-literal=build="${BUILD_NUMBER:-manual}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "==> helm upgrade chatbot-dev: theme=$COLOR (everything else unchanged)"
    helm upgrade chatbot-dev helm/chatbot -n $NS --reuse-values --set theme="$COLOR" --atomic --wait --timeout 3m
    kubectl -n $NS rollout status deployment/ui --timeout=120s
    kubectl -n $NS get pods -l app.kubernetes.io/component=ui -o wide ;;
  verify)
    valid
    ca="${CA_FILE:-certs/chatbot-local-ca.crt}"
    for i in $(seq 20); do
      got=$(curl -fsS --cacert "$ca" --resolve dev.chatbot.local:443:127.0.0.1 https://dev.chatbot.local/theme.json 2>/dev/null || true)
      echo "$got" | grep -q "\"color\": *\"$COLOR\"" && { echo "PASS  https://dev.chatbot.local/theme.json -> $got"; exit 0; }
      sleep 3
    done
    echo "FAIL  dev still serves: ${got:-nothing}"; exit 1 ;;
  show)
    kubectl -n $NS get configmap chatbot-theme -o jsonpath='{.data.color} (requested {.data.requested-at}, build {.data.build}){"\n"}' 2>/dev/null \
      || echo "no colour chosen yet (dev uses values-dev.yaml)" ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
