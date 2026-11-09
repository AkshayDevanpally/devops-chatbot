terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # Stays up for good, like terraform/guardrails: it holds the off-server backup copies.
  # Local state, gitignored. The uploader's access key is NOT made here (it would land in the
  # state); scripts/10-backups.sh offsite-setup creates it straight into a cluster secret.
}

provider "aws" {
  region = var.region # credentials: AWS_PROFILE ("chatbot")
  default_tags {
    tags = { Project = "qwenops", ManagedBy = "terraform", Stack = "backups" }
  }
}
