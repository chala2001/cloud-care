# terraform/serverless-contact/outputs.tf

output "contact_api_url" {
  description = "Public POST /contact endpoint"
  value       = "${aws_apigatewayv2_api.contact.api_endpoint}/contact"
}

output "function_name" {
  description = "Contact Lambda name (for logs)"
  value       = aws_lambda_function.contact.function_name
}
