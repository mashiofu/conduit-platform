variable "name_prefix" {
  description = "Prefix applied to resource names/tags, e.g. \"conduit-dev\"."
  type        = string
}

variable "aws_region" {
  description = "AWS region this network is built in (used to construct the S3 VPC endpoint's service name)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Carved into three /20 subnet tiers (public/private/data) per AZ - see main.tf."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread subnets across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 4
    error_message = "az_count must be between 1 and 4 (the CIDR carving in main.tf reserves room for at most 4 AZs per subnet tier)."
  }
}

variable "single_nat_gateway" {
  description = "Use one shared NAT Gateway instead of one per AZ. Cuts NAT cost roughly in proportion to az_count, trading away NAT fault-tolerance across AZs if that gateway's AZ has an outage - a deliberate, documented dev-environment trade-off (see docs/design-decisions.md). Set false for a production-grade one-NAT-per-AZ setup."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
