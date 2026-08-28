variable "name_prefix" {
  description = "Prefix applied to resource names/tags, e.g. \"conduit-dev\"."
  type        = string
}

variable "vpc_id" {
  description = "VPC to create the cache subnet group and security group in."
  type        = string
}

variable "subnet_ids" {
  description = "Data-tier subnet IDs for the cache subnet group (private, no route to the internet)."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Map of static-label => security group ID allowed to reach Redis on 6379 (e.g. {eks = module.eks.cluster_security_group_id}). A map, not a list - see the identical parameter in the rds module for why (for_each needs statically-known keys; the security group ID itself is often only known at apply time)."
  type        = map(string)
  default     = {}
}

variable "node_type" {
  description = "ElastiCache node type, e.g. \"cache.t4g.micro\"."
  type        = string
  default     = "cache.t4g.micro"
}

variable "engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.1"
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
