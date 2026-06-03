# terraform/observability/sns.tf

# A single SNS topic that every alarm publishes to. SNS fans it out to all
# subscriptions (email here; could add Slack/PagerDuty/SMS later).
resource "aws_sns_topic" "ops" {
  name = "${var.project}-ops-alerts"
}

# Email subscription. AWS sends a confirmation email — you MUST click the link
# in it before alarms start arriving (Terraform shows the subscription as
# "pending confirmation" until you do).
resource "aws_sns_topic_subscription" "ops_email" {
  topic_arn = aws_sns_topic.ops.arn
  protocol  = "email"
  endpoint  = var.alert_email
}