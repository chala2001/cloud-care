# terraform/database/outputs.tf

output "db_endpoint" {
  description = "RDS connection endpoint (host:port)"
  value       = aws_db_instance.main.endpoint
}

output "db_address" {
  description = "RDS hostname"
  value       = aws_db_instance.main.address
}

output "db_port" {
  description = "RDS port"
  value       = aws_db_instance.main.port
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the DB credentials"
  value       = aws_secretsmanager_secret.db.arn
}

output "db_identifier" {
  description = "RDS instance identifier — the DBInstanceIdentifier dimension in CloudWatch RDS metrics"
  value       = aws_db_instance.main.id
}