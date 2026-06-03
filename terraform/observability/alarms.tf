# terraform/observability/alarms.tf

locals {
  alb_arn_suffix   = data.terraform_remote_state.compute.outputs.alb_arn_suffix
  asg_name         = data.terraform_remote_state.compute.outputs.asg_name
  target_group_arn = data.terraform_remote_state.compute.outputs.target_group_arn
  db_identifier    = data.terraform_remote_state.database.outputs.db_identifier
  audit_function   = data.terraform_remote_state.audit.outputs.function_name
  contact_function = data.terraform_remote_state.contact.outputs.function_name
  audit_table      = data.terraform_remote_state.audit.outputs.table_name
}

# --- ALB --------------------------------------------------------------------

# 5xx coming OUT of the ALB itself (target group can't serve OR ALB is misbehaving).
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-alb-5xx"
  alarm_description   = "ALB returned >= 5 HTTP 5xx in the last 5 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = local.alb_arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops.arn]
  ok_actions    = [aws_sns_topic.ops.arn]
}

# ZERO healthy targets means the app is down.
resource "aws_cloudwatch_metric_alarm" "alb_no_healthy" {
  alarm_name        = "${var.project}-alb-no-healthy-hosts"
  alarm_description = "Target group has 0 healthy hosts"
  namespace         = "AWS/ApplicationELB"
  metric_name       = "HealthyHostCount"
  dimensions = {
    LoadBalancer = local.alb_arn_suffix
    TargetGroup  = replace(local.target_group_arn, "/^.*targetgroup\\//", "targetgroup/")
  }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.ops.arn]
}

# --- RDS --------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.project}-rds-cpu-high"
  alarm_description   = "RDS CPU > 80% for 10 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = local.db_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"

  alarm_actions = [aws_sns_topic.ops.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.project}-rds-storage-low"
  alarm_description   = "RDS free storage < 2 GB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = local.db_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2 * 1024 * 1024 * 1024 # 2 GB in bytes
  comparison_operator = "LessThanThreshold"

  alarm_actions = [aws_sns_topic.ops.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.project}-rds-connections-high"
  alarm_description   = "RDS connections > 80 (db.t3.micro caps around ~100)"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = local.db_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"

  alarm_actions = [aws_sns_topic.ops.arn]
}

# --- Lambda -----------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "audit_errors" {
  alarm_name          = "${var.project}-audit-lambda-errors"
  alarm_description   = "Audit Lambda errored at least once in 5 minutes"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = local.audit_function }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops.arn]
}

resource "aws_cloudwatch_metric_alarm" "contact_errors" {
  alarm_name          = "${var.project}-contact-lambda-errors"
  alarm_description   = "Contact Lambda errored at least once in 5 minutes"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = local.contact_function }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops.arn]
}

# --- DynamoDB ---------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ddb_throttles" {
  alarm_name          = "${var.project}-ddb-throttled"
  alarm_description   = "Audit table threw any throttled request in 5 min"
  namespace           = "AWS/DynamoDB"
  metric_name         = "ThrottledRequests"
  dimensions          = { TableName = local.audit_table }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops.arn]
}