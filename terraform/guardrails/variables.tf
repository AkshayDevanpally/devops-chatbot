variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "alert_email" {
  description = "Budget emails go here. Set in terraform.tfvars (gitignored), never committed."
  type        = string
}

variable "monthly_limit_usd" {
  type    = number
  default = 10
}

variable "iam_user" {
  description = "The IAM user Terraform runs as; it loses the right to create machines at 100%."
  type        = string
  default     = "chatbot-terraform"
}
