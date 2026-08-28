variable "name_prefix" {
  description = "Prefix applied to resource names/tags, e.g. \"conduit-dev\"."
  type        = string
}

variable "vpc_id" {
  description = "VPC to create the DB subnet group and security group in."
  type        = string
}

variable "subnet_ids" {
  description = "Data-tier subnet IDs for the DB subnet group (private, no route to the internet)."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Map of static-label => security group ID allowed to reach Postgres on 5432 (e.g. {eks = module.eks.cluster_security_group_id}). A map, not a list: the security group ID is often an apply-time value (unknown at plan time), and for_each requires its *keys* to be known upfront - a list built from an unknown value makes the whole key set unknown, which for_each rejects. The map's keys are static labels chosen by the caller; only the values need to resolve at apply time."
  type        = map(string)
  default     = {}
}

variable "instance_class" {
  description = "RDS instance class, e.g. \"db.t4g.micro\"."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage_gb" {
  description = "Initial allocated storage, in GB. max_allocated_storage (the storage-autoscaling ceiling) is derived as 5x this value."
  type        = number
  default     = 20
}

variable "engine_version" {
  description = "Postgres engine version. Pin a real minor version (not just a bare major like \"17\") - RDS resolves a bare major to whatever the current latest minor is at creation time, which then shows as permanent drift on every later `plan`. Checked against `aws rds describe-db-engine-versions --engine postgres` on 2026-08-26; 17.11 was the latest generally-available minor at that time."
  type        = string
  default     = "17.11"
}

variable "database_name" {
  description = "Initial database name created inside the instance."
  type        = string
  default     = "conduit"
}

variable "master_username" {
  description = "Master username. The password itself is never set here - see manage_master_user_password in main.tf."
  type        = string
  default     = "conduit_admin"
}

variable "multi_az" {
  description = "Multi-AZ standby for automatic failover. Off by default for this dev/take-home environment to control cost - see docs/design-decisions.md."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention, in days. 0 disables automated backups entirely - RDS's own valid range is 0-35."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 0 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 0 and 35 (RDS's own supported range)."
  }
}

variable "deletion_protection" {
  description = "Block the instance from being deleted (via the AWS API or a `terraform destroy`) until this is explicitly turned off."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. true is fine for a dev/take-home environment where teardown is expected; set false for anything real."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
