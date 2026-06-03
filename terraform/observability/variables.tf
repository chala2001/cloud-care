# terraform/observability/variables.tf
variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "cloudcare"
}

# Where SNS sends "something is broken" emails.
variable "alert_email" {
  description = "Email that receives ops alerts (you'll need to confirm a subscription email)"
  type        = string
}