output "budget_name" { value = aws_budgets_budget.monthly.name }
output "kill_switch" { value = aws_lambda_function.kill_switch.function_name }
output "deny_policy_arn" { value = aws_iam_policy.deny_create.arn }
