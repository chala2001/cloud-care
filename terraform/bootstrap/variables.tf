variable "aws_region" {
  description = "AWS region for the state backend"
  type        = string
  default     = "ap-south-1"
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name for Terraform state"
  type        = string
  # no default — you must pass it, so you can't forget the account-id suffix
}

variable "lock_table_name" {
  description = "DynamoDB table name for Terraform state locks"
  type        = string
  default     = "cloudcare-tf-locks"
}