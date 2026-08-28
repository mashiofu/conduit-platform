variable "name_prefix" {
  description = "Prefix applied to resource names/tags, e.g. \"conduit-dev\"."
  type        = string
}

variable "bucket_name" {
  description = "Globally-unique S3 bucket name for the built frontend SPA."
  type        = string
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 (US/Canada/Europe edge locations only) is the cheapest option and is a fine default for a dev/demo environment."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be one of: PriceClass_100, PriceClass_200, PriceClass_All."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
