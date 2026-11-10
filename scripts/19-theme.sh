#!/usr/bin/env bash
# "Be a Dev" colour deploys (ci/theme-deploy.Jenkinsfile, started from the site). Each environment's
# Be a Dev page changes only that environment's colour. ENV is dev, qa or prod (default dev).
#
#   ./scripts/19-theme.sh validate COLOR [ENV]   # only the six allowed colours and the three environments
#   ./scripts/19-theme.sh deploy COLOR [ENV]     # remember it, then roll that env's UI with the new colour
#   ./scripts/19-theme.sh verify COLOR [ENV]     # the site serves it (theme.json over HTTPS, home CA)
#   ./scripts/19-theme.sh show [ENV]             # current chosen colour (all three without ENV)
#
# The colour is kept in ConfigMap chatbot-theme in that env's namespace, so a normal pipeline deploy
# (scripts/06-deploy.sh) keeps it instead of resetting it to helm/chatbot/values-<env>.yaml.
set -euo pipefail
cd "$(dirname "$0")/.."
ALLOWED="teal indigo rose amber emerald slate"
CMD="${1:-}"
if [[ $CMD == show ]]; then COLOR=""; ENV="${2:-}"; else COLOR="${2:-}"; ENV="${3:-dev}"; fi

valid_env() { [[ $1 =~ ^(dev|qa|prod)$ ]] || { echo "environment must be dev, qa or prod (got '$1')"; exit 1; }; }
valid() {
  [[ " $ALLOWED " == *" $COLOR "* ]] || { echo "colour must be one of: $ALLOWED (got '$COLOR')"; exit 1; }
  valid_env "$ENV"
}
host() { [[ $1 == prod ]] && echo chatbot.local || echo "$1.chatbot.local"; }

# A pipeline deploy may be upgrading the same release; wait for it instead of failing on Helm's lock.
wait_for_release() {
  for _ in $(seq 60); do
    st=$(helm status "chatbot-$ENV" -n "chatbot-$ENV" -o json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])' || echo unknown)
    [[ $st == pending-* ]] || return 0
    echo "chatbot-$ENV is busy ($st): waiting for the other deploy to finish…"; sleep 5
  done
  echo "chatbot-$ENV still busy after 5 minutes"; exit 1
}

case "$CMD" in
  validate)
    valid; echo "colour '$COLOR' for $ENV is allowed" ;;
  deploy)
    valid
    NS="chatbot-$ENV"
    before=$(kubectl -n "$NS" get configmap ui-theme -o jsonpath='{.data.theme\.json}' 2>/dev/null || echo "?")
    echo "$ENV now: $before"
    kubectl -n "$NS" create configmap chatbot-theme --from-literal=color="$COLOR" \
      --from-literal=requested-at="$(date -u +%FT%TZ)" --from-literal=build="${BUILD_NUMBER:-manual}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    wait_for_release
    # Pass the running image tag again, as text: a release deployed with an all-digit commit id may have it
    # stored as a number, which --reuse-values would render as 5.151604e+06 (Issue 49).
    tag=$(helm get values "chatbot-$ENV" -n "$NS" -o json | python3 -I -c 'import json,sys
t = json.load(sys.stdin).get("image", {}).get("tag")
print(int(t) if isinstance(t, float) and t.is_integer() else ("" if t is None else t))')
    echo "==> helm upgrade chatbot-$ENV: theme=$COLOR (image ${tag:-unchanged}, everything else unchanged)"
    helm upgrade "chatbot-$ENV" helm/chatbot -n "$NS" --reuse-values --set theme="$COLOR" \
      ${tag:+--set-string image.tag="$tag"} --atomic --wait --timeout 3m
    kubectl -n "$NS" rollout status deployment/ui --timeout=120s
    kubectl -n "$NS" get pods -l app.kubernetes.io/component=ui -o wide ;;
  verify)
    valid
    ca="${CA_FILE:-certs/chatbot-local-ca.crt}"; h=$(host "$ENV")
    for _ in $(seq 20); do
      got=$(curl -fsS --cacert "$ca" --resolve "$h:443:127.0.0.1" "https://$h/theme.json" 2>/dev/null || true)
      echo "$got" | grep -q "\"color\": *\"$COLOR\"" && { echo "PASS  https://$h/theme.json -> $got"; exit 0; }
      sleep 3
    done
    echo "FAIL  $ENV still serves: ${got:-nothing}"; exit 1 ;;
  show)
    envs="${ENV:-dev qa prod}"
    for e in $envs; do
      valid_env "$e"
      printf '%-5s ' "$e"
      kubectl -n "chatbot-$e" get configmap chatbot-theme -o jsonpath='{.data.color} (requested {.data.requested-at}, build {.data.build}){"\n"}' 2>/dev/null \
        || echo "no colour chosen yet (uses values-$e.yaml)"
    done ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
