# terraform/cdn/variables.tf
variable "aws_region" {
  description = "AWS region (CloudFront is global, but the provider needs one)"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a prefix"
  type        = string
  default     = "cloudcare"
}