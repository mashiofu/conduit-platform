variable "name" {
  description = "Role name, e.g. \"conduit-dev-backend-ci\"."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider (from the iam-github-oidc-provider module - one per account)."
  type        = string
}

variable "github_org" {
  description = "GitHub org/user that owns the repo(s) allowed to assume this role."
  type        = string
}

variable "github_repos" {
  description = "Repo names (without the owner) allowed to assume this role via OIDC, e.g. [\"golang-gin-realworld-example-app\"]."
  type        = list(string)
}

variable "github_environment" {
  description = "If set, scope the trust policy to this GitHub Environment (repo:org/repo:environment:<name>) instead of any ref on the repo (repo:org/repo:*). Pair with a GitHub Environment that has required reviewers/wait timers configured for a real prod deploy gate. Null (the default) allows any branch/ref - fine for dev/staging where you want fast iteration."
  type        = string
  default     = null
}

variable "ecr_repository_arns" {
  description = "ECR repo ARNs this role may push images to."
  type        = list(string)
  default     = []
}

variable "ecr_pull_only_repository_arns" {
  description = "ECR repo ARNs this role may only pull from, not push to - for staging/prod's backend-ci role to read dev's already-built image during promotion (see the backend repo's promote.yml), without granting push access to a repo it doesn't own."
  type        = list(string)
  default     = []
}

variable "s3_read_bucket_arn" {
  description = "A foreign S3 bucket this role may read (list + get) but not write - for staging/prod's frontend-ci role to read dev's already-built assets during promotion, without granting write access to a bucket it doesn't own."
  type        = string
  default     = null
}

variable "frontend_bucket_arn" {
  description = "S3 bucket ARN this role may sync built frontend assets to."
  type        = string
  default     = null
}

variable "cloudfront_distribution_arn" {
  description = "CloudFront distribution ARN this role may invalidate after a deploy."
  type        = string
  default     = null
}

variable "eks_describe_cluster" {
  description = "Grant eks:DescribeCluster/ListClusters (needed for `aws eks update-kubeconfig`). Scoped to \"*\" rather than one cluster's ARN - this role is created before the eks module in the dependency graph (the eks module's access entry needs *this* role's ARN as an input), so scoping to the exact cluster ARN here would be circular. DescribeCluster is a low-risk read-only action; the real gate is the EKS access entry the eks module grants this role, which is cluster-specific."
  type        = bool
  default     = false
}

variable "ssm_read_parameter_arn" {
  description = "SSM parameter ARN this role may read (e.g. the backend's ALB hostname, written there by conduit-platform's deploy workflow after each apply - see docs/design-decisions.md for why that value can't be a Terraform output at all: the ALB is created by the AWS Load Balancer Controller reacting to a Kubernetes Ingress, entirely inside the cluster/AWS runtime, invisible to Terraform)."
  type        = string
  default     = null
}

variable "ssm_write_parameter_arn" {
  description = "SSM parameter ARN this role may write - the counterpart to ssm_read_parameter_arn, granted to whichever role actually discovers the runtime value (conduit-platform's deploy workflow, for the backend's ALB hostname)."
  type        = string
  default     = null
}

variable "admin_access" {
  description = "Attach AdministratorAccess instead of a hand-scoped policy. Used only for the terraform-ci role (see live/main.tf) - Terraform manages IAM roles/policies itself (this module included), which AWS's built-in PowerUserAccess explicitly excludes, and hand-crafting a least-privilege policy across the 9+ services every module here touches wasn't a good time trade-off for this project. Documented as a known gap, not a hidden one: the actual gate is that only conduit-platform's own repo can assume this role at all, behind required PR review plus a GitHub Environment approval on the apply job - not IAM-level scoping. A more mature setup would split plan (read-only) from apply (this) and narrow this policy by service."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the IAM role."
  type        = map(string)
  default     = {}
}
