# terraform/cicd/variables.tf
variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "cloudcare"
}

variable "github_owner" {
  description = "Your GitHub user or organization (e.g., chala2001)"
  type        = string
}

variable "github_repo" {
  description = "The CloudCare repo name (e.g., cloud-care)"
  type        = string
}