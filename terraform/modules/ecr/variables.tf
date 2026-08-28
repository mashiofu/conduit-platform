variable "name" {
  description = "Repository name, e.g. \"conduit-dev-backend\"."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
