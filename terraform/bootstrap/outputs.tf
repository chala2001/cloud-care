output "state_bucket" {
  description = "Name of the S3 state bucket — use this in backend configs"
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table" {
  description = "Name of the DynamoDB lock table — use this in backend configs"
  value       = aws_dynamodb_table.tf_locks.name
}