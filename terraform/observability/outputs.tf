# terraform/observability/outputs.tf

output "ops_topic_arn" {
  value       = aws_sns_topic.ops.arn
  description = "Add more subscriptions (Slack, PagerDuty) to this ARN"
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}