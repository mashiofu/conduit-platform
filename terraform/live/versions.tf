terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pessimistic constraint: allow patch/minor upgrades within v6, but
      # require a deliberate bump (and a re-read of the changelog) to move
      # to v7. Resolved to v6.62.0 as of 2026-08-26 - re-tighten this
      # periodically rather than letting it drift wide open.
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # No remote backend configured yet - this defaults to local state (one
  # state file per workspace, under terraform.tfstate.d/) so
  # `validate`/`plan` work with zero AWS side effects while we're still in
  # "write and validate the code, decide on a real deploy later" mode (see
  # ../bootstrap). Once ready to actually apply for real:
  #
  #   1. cd ../bootstrap && terraform init && \
  #        terraform apply -var="state_bucket_name=<globally-unique-name>"
  #   2. uncomment the EMPTY backend "s3" block below - do NOT fill in
  #      real values here, this file is committed to git. Every actual
  #      value (bucket/key/region/use_lockfile) comes from backend.hcl
  #      (gitignored - see backend.hcl.example) via -backend-config
  #      below, so no account-specific value ever lands in this file.
  #   3. terraform init -backend-config=backend.hcl -migrate-state
  #
  # With workspaces, a single backend key is automatically namespaced per
  # workspace by Terraform itself (env:/<workspace>/<key>) - no per-
  # environment key to manage by hand.
  #
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
