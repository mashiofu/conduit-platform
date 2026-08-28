variable "name_prefix" {
  description = "Prefix applied to resource names/tags, e.g. \"conduit-dev\"."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "Private subnets nodes run in. Also passed to the cluster's own vpc_config."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnets, included in the cluster's vpc_config alongside the private ones (standard EKS reference pattern - control plane ENIs can use either; workloads themselves stay in the private subnets via the node group)."
  type        = list(string)
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version, e.g. \"1.34\". Checked against `aws eks describe-addon-versions` on 2026-08-26; EKS supported 1.31-1.36 at that time."
  type        = string
  default     = "1.34"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT."
  type        = string
  default     = "ON_DEMAND"
}

variable "platform_ci_role_arn" {
  description = "IAM role ARN for conduit-platform's own GitHub Actions CD workflow (the deploy-dispatch receiver) - the only identity, besides whoever applies Terraform by hand, granted access to this cluster."
  type        = string
}

variable "ssm_parameter_path_prefix" {
  description = "SSM Parameter Store path prefix (e.g. \"/conduit/dev\") External Secrets Operator's IAM role may read from. The actual parameters (JWT_SECRET, etc.) are created in Phase 4 alongside the app chart that consumes them - this just grants read access to the path ahead of that."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
