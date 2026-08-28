output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "The cluster security group EKS itself manages - this is what gets granted ingress on RDS/Redis, rather than a hand-rolled parallel one."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_provider_url" {
  value = aws_iam_openid_connect_provider.cluster.url
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "lb_controller_role_arn" {
  description = "For the aws-load-balancer-controller Helm release's serviceAccount.annotations."
  value       = aws_iam_role.lb_controller.arn
}

output "external_secrets_role_arn" {
  description = "For the external-secrets Helm release's serviceAccount.annotations."
  value       = aws_iam_role.external_secrets.arn
}

output "cluster_autoscaler_role_arn" {
  description = "For the cluster-autoscaler Helm release's serviceAccount.annotations."
  value       = aws_iam_role.cluster_autoscaler.arn
}
