# terraform/serverless-audit/outputs.tf

output "api_url" {
  description = "Public endpoint of the audit HTTP API"
  value       = aws_apigatewayv2_api.audit.api_endpoint
}

output "table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.audit.name
}

output "function_name" {
  description = "Lambda function name (for inspecting logs / X-Ray)"
  value       = aws_lambda_function.audit.function_name
}