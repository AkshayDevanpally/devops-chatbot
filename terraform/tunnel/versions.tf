terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # Local state on purpose: nothing here holds data and everything is destroyed after use,
  # so a state bucket (a resource that must outlive the stack) isn't worth it. *.tfstate is gitignored.
}

provider "aws" {
  region = var.region # credentials: AWS_PROFILE (scripts/12-tunnel.sh uses "chatbot")
  default_tags {
    tags = { Project = "qwenops", ManagedBy = "terraform", Stack = "tunnel", Ephemeral = "true" }
  }
}
