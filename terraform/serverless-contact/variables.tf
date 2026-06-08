# terraform/serverless-contact/variables.tf
variable "aws_region" {
  description = "AWS region (use one where SES is available)"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a prefix"
  type        = string
  default     = "cloudcare"
}

# Required — no defaults, so you cant accidentally email someone else's address.
variable "sender_email" {
  description = "Verified SES sender (the From: address shown to the recipient)"
  type        = string
}

variable "recipient_email" {
  description = "Verified SES recipient — the hospital admin inbox"
  type        = string
}