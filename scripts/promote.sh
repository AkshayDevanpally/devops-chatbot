#!/usr/bin/env bash
# Usage: ./scripts/promote.sh <dev|qa|prod> <tag>
# Deploy, verify, and roll back automatically if verification fails: a failed promotion leaves the
# environment on the release it had before, so a red build never means "broken release is live".
# Used by the Jenkinsfile; manual deploys can keep using make deploy-* and make verify.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV="${1:?usage: $0 <dev|qa|prod> <tag>}"
TAG="${2:?usage: $0 <dev|qa|prod> <tag>}"
REL="chatbot-$ENV"; NS="chatbot-$ENV"

# The release currently live (empty on a first install: nothing to roll back to).
PREV=$(helm history "$REL" -n "$NS" --max 20 -o json 2>/dev/null \
  | python3 -c 'import json,sys; d=[r for r in json.load(sys.stdin) if r["status"]=="deployed"]; print(d[-1]["revision"] if d else "")' \
  2>/dev/null || true)

./scripts/06-deploy.sh "$ENV" "$TAG"

if ./scripts/07-verify.sh "$ENV"; then
  echo "==> $TAG verified in $ENV"
  exit 0
fi

if [[ -z $PREV ]]; then
  echo "!! verification failed in $ENV and there is no earlier release to roll back to"
  exit 1
fi
echo "!! verification failed in $ENV: rolling back to revision $PREV"
helm rollback "$REL" "$PREV" -n "$NS" --wait --timeout 5m
helm history "$REL" -n "$NS" --max 3
echo "!! $ENV is back on revision $PREV. $TAG was NOT kept. Fix the failure and push again."
exit 1
