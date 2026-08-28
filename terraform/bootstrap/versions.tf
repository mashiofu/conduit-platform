terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Same pessimistic constraint as terraform/live - see that module's
      # versions.tf for the rationale.
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
