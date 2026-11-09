#!/usr/bin/env bash
# AWS cost guardrails: $10/month budget, deny-create policy + kill switch at 100%.
#
#   ./scripts/14-guardrails.sh up       # create or update (the one AWS stack that stays up; costs $0)
#   ./scripts/14-guardrails.sh test     # kill switch in dry-run mode: lists what it would remove
#   ./scripts/14-guardrails.sh status   # spend so far, budget action state, deny policy attached?
#   ./scripts/14-guardrails.sh reset    # after a cut-off: give the Terraform user its rights back
#
# The alert email lives in terraform/guardrails/terraform.tfvars (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE="${AWS_PROFILE:-chatbot}"
TF="terraform -chdir=terraform/guardrails"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
out() { $TF output -raw "$1" 2>/dev/null || true; }

up() {
  [ -s terraform/guardrails/terraform.tfvars ] || {
    echo "create terraform/guardrails/terraform.tfvars with: alert_email = \"you@example.com\""; exit 1; }
  $TF init -input=false >/dev/null
  $TF apply -input=false -auto-approve
  echo; echo "Budget emails need no confirmation. Check: make guardrails-test / guardrails-status"
}

test_switch() {
  fn=$(out kill_switch); [ -n "$fn" ] || { echo "not set up: run 'up' first"; exit 1; }
  f=$(mktemp)
  aws lambda invoke --function-name "$fn" --cli-binary-format raw-in-base64-out \
    --payload '{"dry_run": true}' "$f" >/dev/null
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))
print("dry run, regions checked:", r["regions_checked"])
print("would remove:", json.dumps(r["acted_on"]) if r["acted_on"] else "nothing (no instances, Spot requests, NAT gateways or loose Elastic IPs)")
print("errors:", r["errors"] or "none")' "$f"
  rm -f "$f"
}

status() {
  b=$(out budget_name); [ -n "$b" ] || { echo "not set up"; exit 1; }
  aws budgets describe-budget --account-id "$ACCOUNT" --budget-name "$b" \
    --query 'Budget.{limit:BudgetLimit.Amount, spent:CalculatedSpend.ActualSpend.Amount, forecast:CalculatedSpend.ForecastedSpend.Amount}' --output table
  aws budgets describe-budget-actions-for-budget --account-id "$ACCOUNT" --budget-name "$b" \
    --query 'Actions[].{action:ActionType, status:Status}' --output table
  if aws iam list-attached-user-policies --user-name chatbot-terraform --query 'AttachedPolicies[].PolicyArn' --output text \
     | grep -q "$(out deny_policy_arn)"; then echo "deny policy: ATTACHED (cut-off happened; see 'reset')"
  else echo "deny policy: not attached"; fi
}

reset() {
  b=$(out budget_name); id=$(aws budgets describe-budget-actions-for-budget --account-id "$ACCOUNT" \
    --budget-name "$b" --query 'Actions[0].ActionId' --output text)
  if aws budgets execute-budget-action --account-id "$ACCOUNT" --budget-name "$b" --action-id "$id" \
       --execution-type REVERSE_BUDGET_ACTION >/dev/null 2>&1; then
    echo "budget action reversed: deny policy removed"
  else
    aws iam detach-user-policy --user-name chatbot-terraform --policy-arn "$(out deny_policy_arn)" 2>/dev/null \
      && echo "deny policy detached" || echo "deny policy was not attached"
  fi
  echo "Note: if spend is still over the limit this month, the action can fire again."
}

case "${1:-}" in
  up) up ;; test) test_switch ;; status) status ;; reset) reset ;;
  *) echo "usage: $0 up|test|status|reset"; exit 2 ;;
esac
