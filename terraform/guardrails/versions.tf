terraform {
  required_version = ">= 1.9"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.7" }
  }
  # The one AWS stack that stays up for good (it costs nothing). Local state, gitignored; if it is
  # lost, the resources stay and can be imported or deleted by name (all start with "qwenops-").
}

provider "aws" {
  region = var.region # credentials: AWS_PROFILE (scripts/14-guardrails.sh uses "chatbot")
  default_tags {
    tags = { Project = "qwenops", ManagedBy = "terraform", Stack = "guardrails" }
  }
}
