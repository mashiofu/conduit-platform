# Single root module, differentiated per environment by Terraform
# workspace (dev / staging / prod) rather than one directory per
# environment. That trades away some filesystem-level guardrails for less
# duplication - see docs/design-decisions.md for the full tradeoff - so
# the mitigations below matter:
#
#   1. every prod-vs-dev difference lives in ONE map (env_config), not
#      scattered `terraform.workspace == "x" ? ... : ...` conditionals
#      through the codebase
#   2. the check block below refuses to plan/apply at all against the
#      'default' workspace, so there's no ambiguous, unlabeled
#      environment that real infrastructure can silently land in
#   3. prod's GitHub Actions role trusts only GitHub's own "prod"
#      Environment (with whatever required-reviewer/wait-timer rules are
#      configured on the repo), not just "any push to this repo"

# A hard gate, not a `check` block: `check` block assertion failures are
# advisory warnings in Terraform - they do NOT stop a plan/apply from
# succeeding, which makes them the wrong tool for something that must
# actually block. A resource `precondition` does hard-fail, so that's
# what enforces this - every module below has an explicit
# `depends_on = [terraform_data.workspace_guard]` specifically so
# Terraform evaluates (and can fail on) this precondition before
# attempting anything else, rather than the two failing independently
# with the guard's failure buried among others.
resource "terraform_data" "workspace_guard" {
  input = terraform.workspace

  lifecycle {
    precondition {
      condition     = contains(["dev", "staging", "prod"], terraform.workspace)
      error_message = "terraform.workspace must be dev, staging, or prod (got '${terraform.workspace}'). Run `terraform workspace new <env>` (first time) or `terraform workspace select <env>`. The 'default' workspace must never hold real infrastructure."
    }
  }
}

locals {
  environment = terraform.workspace
  # Guaranteed to be a valid key even when terraform.workspace isn't -
  # falls back to "dev" purely so this map index never throws its own
  # (unhelpful, unlabeled) error. terraform_data.workspace_guard's
  # precondition above is what actually blocks an invalid workspace; this
  # fallback value is never used for anything real when that's the case.
  valid_workspace = contains(["dev", "staging", "prod"], local.environment)
  name_prefix     = "${var.project}-${local.environment}"

  common_tags = {
    Project     = var.project
    Environment = local.environment
    ManagedBy   = "terraform"
  }

  # Everything that varies by environment, in one place. Add a new
  # environment by adding a new key here (and to the `check` block above)
  # - nowhere else in this file should ever need a
  # `terraform.workspace == "..."` conditional.
  env_config = {
    dev = {
      vpc_cidr               = "10.20.0.0/16"
      az_count               = 2
      single_nat_gateway     = true
      db_instance_class      = "db.t4g.micro"
      db_multi_az            = false
      db_deletion_protection = false
      db_skip_final_snapshot = true
      redis_node_type        = "cache.t4g.micro"
      github_environment     = null # any branch/ref may deploy
      kubernetes_version     = "1.34"
      node_instance_types    = ["t3.medium"]
      node_desired_size      = 2
      node_min_size          = 1
      node_max_size          = 4
      node_capacity_type     = "ON_DEMAND"
    }
    staging = {
      vpc_cidr               = "10.21.0.0/16"
      az_count               = 2
      single_nat_gateway     = true
      db_instance_class      = "db.t4g.small"
      db_multi_az            = false
      db_deletion_protection = false
      db_skip_final_snapshot = true
      redis_node_type        = "cache.t4g.small"
      github_environment     = null
      kubernetes_version     = "1.34"
      node_instance_types    = ["t3.medium"]
      node_desired_size      = 2
      node_min_size          = 1
      node_max_size          = 4
      node_capacity_type     = "ON_DEMAND"
    }
    prod = {
      vpc_cidr               = "10.22.0.0/16"
      az_count               = 3
      single_nat_gateway     = false # NAT-per-AZ: an AZ outage shouldn't take egress with it
      db_instance_class      = "db.t4g.medium"
      db_multi_az            = true
      db_deletion_protection = true
      db_skip_final_snapshot = false
      redis_node_type        = "cache.t4g.medium"
      github_environment     = "prod" # only GitHub's "prod" Environment may assume this role - same name as this workspace, deliberately
      kubernetes_version     = "1.34"
      node_instance_types    = ["t3.large"]
      node_desired_size      = 3
      node_min_size          = 2
      node_max_size          = 6
      node_capacity_type     = "ON_DEMAND"
    }
  }

  cfg = local.env_config[local.valid_workspace ? local.environment : "dev"]

  frontend_bucket_name = "${local.name_prefix}-frontend-${var.github_org}"

  # The backend's ALB hostname, written here by conduit-platform's deploy
  # workflow after each `helmfile apply` (kubectl get ingress ...) - not a
  # Terraform resource, since the ALB itself is created by the AWS Load
  # Balancer Controller reacting to a Kubernetes Ingress, invisible to
  # Terraform. Constructed as a plain string (not a resource output) so
  # both IAM roles below can reference it without either depending on a
  # resource that doesn't exist in this state.
  backend_url_parameter_name = "/${var.project}/${local.environment}/BACKEND_URL"
  backend_url_parameter_arn  = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.live.account_id}:parameter${local.backend_url_parameter_name}"

  # Constructed, not read from dev's own state (a separate workspace's
  # state isn't reachable from here without a cross-state data source
  # this project doesn't set up) - both follow the same deterministic
  # naming every environment already uses, so staging/prod can compute
  # "what dev's would be named" without depending on it. Used only to
  # grant staging/prod's CI roles read access to dev's already-built
  # artifacts during promotion (see the app repos' promote.yml).
  dev_ecr_repository_arn          = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.live.account_id}:repository/${var.project}-dev-backend"
  dev_ecr_frontend_repository_arn = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.live.account_id}:repository/${var.project}-dev-frontend"
  dev_frontend_bucket_arn         = "arn:aws:s3:::${var.project}-dev-frontend-${var.github_org}"
}

data "aws_caller_identity" "live" {}

module "network" {
  source     = "../modules/network"
  depends_on = [terraform_data.workspace_guard]

  name_prefix        = local.name_prefix
  aws_region         = var.aws_region
  vpc_cidr           = local.cfg.vpc_cidr
  az_count           = local.cfg.az_count
  single_nat_gateway = local.cfg.single_nat_gateway
  tags               = local.common_tags
}

module "ecr_backend" {
  source     = "../modules/ecr"
  depends_on = [terraform_data.workspace_guard]

  name = "${local.name_prefix}-backend"
  tags = local.common_tags
}

# The frontend's own image repo, now that it's containerized and running
# on EKS instead of a static S3/CloudFront build - see
# docs/design-decisions.md. module.cdn_frontend (below) stays in place
# for now, retired in a separate follow-up once this path is confirmed
# working end to end, not removed in the same change that adds its
# replacement.
module "ecr_frontend" {
  source     = "../modules/ecr"
  depends_on = [terraform_data.workspace_guard]

  name = "${local.name_prefix}-frontend"
  tags = local.common_tags
}

module "github_oidc_provider" {
  source     = "../modules/iam-github-oidc-provider"
  depends_on = [terraform_data.workspace_guard]

  tags = local.common_tags
}

module "github_role_backend" {
  source     = "../modules/iam-github-actions-role"
  depends_on = [terraform_data.workspace_guard]

  name               = "${local.name_prefix}-backend-ci"
  oidc_provider_arn  = module.github_oidc_provider.arn
  github_org         = var.github_org
  github_repos       = [var.backend_github_repo]
  github_environment = local.cfg.github_environment

  ecr_repository_arns = [module.ecr_backend.repository_arn]
  # Only staging/prod need to read dev's repo (that's the promotion
  # source); dev promoting from itself would be meaningless.
  ecr_pull_only_repository_arns = local.environment == "dev" ? [] : [local.dev_ecr_repository_arn]

  tags = local.common_tags
}

module "github_role_frontend" {
  source     = "../modules/iam-github-actions-role"
  depends_on = [terraform_data.workspace_guard]

  name               = "${local.name_prefix}-frontend-ci"
  oidc_provider_arn  = module.github_oidc_provider.arn
  github_org         = var.github_org
  github_repos       = [var.frontend_github_repo]
  github_environment = local.cfg.github_environment

  # S3/CloudFront perms kept for now alongside the new ECR ones below -
  # module.cdn_frontend itself is still in place during the transition
  # to a containerized frontend (see its own comment). Remove both
  # together once that transition is confirmed working.
  frontend_bucket_arn         = module.cdn_frontend.bucket_arn
  cloudfront_distribution_arn = module.cdn_frontend.distribution_arn
  s3_read_bucket_arn          = local.environment == "dev" ? null : local.dev_frontend_bucket_arn

  ssm_read_parameter_arn = local.backend_url_parameter_arn

  ecr_repository_arns = [module.ecr_frontend.repository_arn]
  # Only staging/prod need to read dev's repo (the promotion source);
  # dev promoting from itself would be meaningless - same pattern as
  # the backend's role above.
  ecr_pull_only_repository_arns = local.environment == "dev" ? [] : [local.dev_ecr_frontend_repository_arn]

  tags = local.common_tags
}

module "github_role_terraform_ci" {
  source     = "../modules/iam-github-actions-role"
  depends_on = [terraform_data.workspace_guard]

  # Bootstrapping note: this role doesn't exist yet the first time anyone
  # applies this config, so that first apply has to run as a human (via
  # whatever IAM identity's credentials/profile you configured - see
  # deploy.env.example) - same as everything else in this repo so far.
  # Once it exists, CI can take over subsequent applies.
  name              = "${local.name_prefix}-terraform-ci"
  oidc_provider_arn = module.github_oidc_provider.arn
  github_org        = var.github_org
  github_repos      = [var.platform_github_repo]
  admin_access      = true

  tags = local.common_tags
}

module "github_role_platform_ci" {
  source     = "../modules/iam-github-actions-role"
  depends_on = [terraform_data.workspace_guard]

  name              = "${local.name_prefix}-platform-ci"
  oidc_provider_arn = module.github_oidc_provider.arn
  github_org        = var.github_org
  github_repos      = [var.platform_github_repo]
  # Not gated to a GitHub Environment even in prod (unlike the app repos'
  # roles) - conduit-platform's own deploy workflow is what enforces
  # per-environment approval, via which repository_dispatch payload it
  # was willing to act on. Revisit if that turns out not to be enough of
  # a gate on its own.
  eks_describe_cluster    = true
  ssm_write_parameter_arn = local.backend_url_parameter_arn

  tags = local.common_tags
}

module "cdn_frontend" {
  source     = "../modules/cdn-frontend"
  depends_on = [terraform_data.workspace_guard]

  name_prefix = local.name_prefix
  bucket_name = local.frontend_bucket_name
  tags        = local.common_tags
}

module "rds" {
  source     = "../modules/rds"
  depends_on = [terraform_data.workspace_guard]

  name_prefix         = local.name_prefix
  vpc_id              = module.network.vpc_id
  subnet_ids          = module.network.data_subnet_ids
  instance_class      = local.cfg.db_instance_class
  multi_az            = local.cfg.db_multi_az
  deletion_protection = local.cfg.db_deletion_protection
  skip_final_snapshot = local.cfg.db_skip_final_snapshot

  # The EKS cluster's security group - closes the gap left open since
  # Phase 2, when this tier didn't exist yet. A map (not a list) because
  # the security group ID isn't known until the cluster is actually
  # created - see the variable's description in modules/rds.
  allowed_security_group_ids = { eks = module.eks.cluster_security_group_id }

  tags = local.common_tags
}

module "elasticache" {
  source     = "../modules/elasticache"
  depends_on = [terraform_data.workspace_guard]

  name_prefix = local.name_prefix
  vpc_id      = module.network.vpc_id
  subnet_ids  = module.network.data_subnet_ids
  node_type   = local.cfg.redis_node_type

  allowed_security_group_ids = { eks = module.eks.cluster_security_group_id }

  tags = local.common_tags
}

# The backend's JWT signing secret. Generated here, read only by External
# Secrets Operator (via the SSM read permissions already scoped in
# modules/eks) into the cluster - never passed through a CI variable, a
# tfvars file, or anyone's shell history.
resource "random_password" "jwt_secret" {
  depends_on = [terraform_data.workspace_guard]

  length  = 64
  special = false # SecureString values don't need shell-hostile characters
}

resource "aws_ssm_parameter" "jwt_secret" {
  depends_on = [terraform_data.workspace_guard]

  name  = "/${var.project}/${local.environment}/JWT_SECRET"
  type  = "SecureString"
  value = random_password.jwt_secret.result
  tags  = local.common_tags
}

module "eks" {
  source     = "../modules/eks"
  depends_on = [terraform_data.workspace_guard]

  name_prefix         = local.name_prefix
  vpc_id              = module.network.vpc_id
  private_subnet_ids  = module.network.private_subnet_ids
  public_subnet_ids   = module.network.public_subnet_ids
  kubernetes_version  = local.cfg.kubernetes_version
  node_instance_types = local.cfg.node_instance_types
  node_desired_size   = local.cfg.node_desired_size
  node_min_size       = local.cfg.node_min_size
  node_max_size       = local.cfg.node_max_size
  node_capacity_type  = local.cfg.node_capacity_type

  platform_ci_role_arn = module.github_role_platform_ci.role_arn

  # External Secrets Operator's IAM role is scoped to this SSM path (the
  # actual parameters under it - JWT_SECRET, etc. - are created in
  # Phase 4 alongside the app chart that consumes them) plus RDS-managed
  # secrets generally, by naming convention - see iam-irsa.tf in the eks
  # module for why not the exact secret ARN.
  ssm_parameter_path_prefix = "/${var.project}/${local.environment}"

  tags = local.common_tags
}
