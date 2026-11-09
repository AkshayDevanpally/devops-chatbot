# Cost guardrails: a monthly budget that, at 100% of actual spend,
#   1. attaches a deny policy to the Terraform user (budget action): nothing new can be created;
#   2. calls a kill-switch Lambda (through SNS): every EC2 instance in every region is terminated.
# AWS billing data lags by several hours, so this is a backstop, not an exact cap. The burst
# node's own idle and max-lifetime timers are the first line.

data "aws_caller_identity" "me" {}
data "aws_iam_user" "terraform" { user_name = var.iam_user }

locals {
  name = "qwenops-guardrails"
}

# ---------------------------------------------------------------- budget + emails
resource "aws_budgets_budget" "monthly" {
  name         = "qwenops-monthly-${var.monthly_limit_usd}usd"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [50, 80]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }
  notification { # early warning: on track to pass the limit this month
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
  notification { # the cut-off: email + SNS -> kill-switch Lambda
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.cutoff.arn]
  }
}

# ---------------------------------------------------------------- 1. deny creating anything that costs
resource "aws_iam_policy" "deny_create" {
  name        = "qwenops-budget-deny-create"
  description = "Attached by the budget action at 100%: no new compute. Deleting still works."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "BudgetReachedNoNewSpend"
      Effect = "Deny"
      Action = [
        "ec2:RunInstances", "ec2:StartInstances", "ec2:RequestSpotInstances", "ec2:RequestSpotFleet",
        "ec2:CreateFleet", "ec2:CreateNatGateway", "ec2:AllocateAddress",
        "autoscaling:CreateAutoScalingGroup", "autoscaling:UpdateAutoScalingGroup",
        "ecs:CreateService", "ecs:RunTask", "eks:CreateCluster", "eks:CreateNodegroup",
        "rds:CreateDBInstance", "rds:CreateDBCluster", "lightsail:Create*", "sagemaker:Create*",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "budget_action" {
  name = "qwenops-budget-action"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "budgets.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "budget_action" {
  name = "attach-deny-policy-only"
  role = aws_iam_role.budget_action.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["iam:AttachUserPolicy", "iam:DetachUserPolicy"]
      Resource  = data.aws_iam_user.terraform.arn
      Condition = { ArnEquals = { "iam:PolicyARN" = aws_iam_policy.deny_create.arn } }
    }]
  })
}

resource "aws_budgets_budget_action" "deny_create" {
  budget_name        = aws_budgets_budget.monthly.name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "AUTOMATIC"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_action.arn

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 100
  }
  definition {
    iam_action_definition {
      policy_arn = aws_iam_policy.deny_create.arn
      users      = [var.iam_user]
    }
  }
  subscriber {
    address           = var.alert_email
    subscription_type = "EMAIL"
  }
}

# ---------------------------------------------------------------- 2. kill switch
resource "aws_sns_topic" "cutoff" {
  name = "qwenops-budget-cutoff"
}

resource "aws_sns_topic_policy" "cutoff" {
  arn = aws_sns_topic.cutoff.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "BudgetsMayPublish"
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.cutoff.arn
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.me.account_id } }
    }]
  })
}

data "archive_file" "kill_switch" {
  type        = "zip"
  source_file = "${path.module}/lambda/kill_switch.py"
  output_path = "${path.module}/.build/kill_switch.zip"
}

resource "aws_iam_role" "kill_switch" {
  name = "qwenops-kill-switch"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "kill_switch" {
  name = "terminate-compute"
  role = aws_iam_role.kill_switch.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeRegions", "ec2:DescribeInstances", "ec2:ModifyInstanceAttribute", "ec2:TerminateInstances",
          "ec2:DescribeSpotInstanceRequests", "ec2:CancelSpotInstanceRequests",
          "ec2:DescribeNatGateways", "ec2:DeleteNatGateway", "ec2:DescribeAddresses", "ec2:ReleaseAddress",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.kill_switch.arn}:*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "kill_switch" {
  name              = "/aws/lambda/qwenops-kill-switch"
  retention_in_days = 90
}

resource "aws_lambda_function" "kill_switch" {
  function_name    = "qwenops-kill-switch"
  role             = aws_iam_role.kill_switch.arn
  runtime          = "python3.13"
  handler          = "kill_switch.handler"
  filename         = data.archive_file.kill_switch.output_path
  source_code_hash = data.archive_file.kill_switch.output_base64sha256
  timeout          = 300 # every region, one after another
  memory_size      = 256
  depends_on       = [aws_cloudwatch_log_group.kill_switch]
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "BudgetCutoffTopic"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.kill_switch.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cutoff.arn
}

resource "aws_sns_topic_subscription" "kill_switch" {
  topic_arn = aws_sns_topic.cutoff.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.kill_switch.arn
}
