variable "aws_region" {
  description = "AWS region for the Terraform state bucket."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name to hold Terraform remote state for every other root module in this repo (terraform/live/)."
  type        = string
}
