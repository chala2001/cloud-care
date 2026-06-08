# terraform/cicd/outputs.tf
output "deploy_role_arn" {
  description = "Set this as the GitHub Actions repo variable AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.deploy.arn
}