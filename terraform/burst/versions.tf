terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # Local state on purpose (see terraform/tunnel): nothing here holds data, everything is destroyed
  # after use. *.tfstate is gitignored.
}

provider "aws" {
  region = var.region # credentials: AWS_PROFILE (scripts/13-burst.sh uses "chatbot")
  default_tags {
    tags = { Project = "qwenops", ManagedBy = "terraform", Stack = "burst", Ephemeral = "true" }
  }
}
