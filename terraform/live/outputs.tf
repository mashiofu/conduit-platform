output "environment" {
  value = local.environment
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "ecr_backend_repository_url" {
  value = module.ecr_backend.repository_url
}

output "ecr_frontend_repository_url" {
  value = module.ecr_frontend.repository_url
}

output "github_actions_backend_role_arn" {
  value = module.github_role_backend.role_arn
}

output "github_actions_frontend_role_arn" {
  value = module.github_role_frontend.role_arn
}

output "github_actions_platform_role_arn" {
  value = module.github_role_platform_ci.role_arn
}

output "github_actions_terraform_role_arn" {
  value = module.github_role_terraform_ci.role_arn
}

output "rds_endpoint" {
  value = module.rds.endpoint
}

output "rds_master_user_secret_arn" {
  value = module.rds.master_user_secret_arn
}

output "rds_database_name" {
  value = module.rds.database_name
}

output "redis_endpoint" {
  value = module.elasticache.primary_endpoint_address
}

# ---- Consumed by conduit-platform/helm/scripts/generate-terraform-values.sh
# to bridge into Helmfile values, rather than anyone hand-copying these. ----

output "aws_region" {
  value = var.aws_region
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_lb_controller_role_arn" {
  value = module.eks.lb_controller_role_arn
}

output "eks_external_secrets_role_arn" {
  value = module.eks.external_secrets_role_arn
}

output "eks_cluster_autoscaler_role_arn" {
  value = module.eks.cluster_autoscaler_role_arn
}

output "backend_url_parameter_name" {
  description = "SSM parameter conduit-platform's deploy workflow writes the backend's ALB hostname to, and the frontend's build reads it from."
  value       = local.backend_url_parameter_name
}
