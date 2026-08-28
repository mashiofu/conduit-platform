# Values that DON'T vary by environment. Anything that does vary
# (sizing, HA, deletion protection, ...) lives in the env_config map in
# main.tf instead, keyed by terraform.workspace - see the comment there
# for why that's one map instead of scattered conditionals.

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "conduit"
}

variable "github_org" {
  description = "GitHub org/user that owns the app repos (used to scope the OIDC trust policies)."
  type        = string
  default     = "mashiofu"
}

variable "backend_github_repo" {
  type    = string
  default = "golang-gin-realworld-example-app"
}

variable "frontend_github_repo" {
  type    = string
  default = "angular-realworld-example-app"
}

variable "platform_github_repo" {
  description = "This repo (conduit-platform) - the only GitHub Actions identity ever granted access to the live cluster."
  type        = string
  default     = "conduit-platform"
}
