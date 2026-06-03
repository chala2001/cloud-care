# terraform/observability/dashboard.tf

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "ALB — Requests & 5xx",
          region = var.aws_region,
          view   = "timeSeries", stacked = false, period = 60,
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_arn_suffix, { stat = "Sum" }],
            [".", "HTTPCode_ELB_5XX_Count", ".", ".", { stat = "Sum", yAxis = "right" }],
            [".", "TargetResponseTime", ".", ".", { stat = "Average", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title  = "ALB — Healthy hosts",
          region = var.aws_region, view = "timeSeries", period = 60,
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", local.alb_arn_suffix, { stat = "Average" }],
            [".", "UnHealthyHostCount", ".", ".", { stat = "Average" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "RDS — CPU, connections, free storage",
          region = var.aws_region, view = "timeSeries", period = 60,
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.db_identifier, { stat = "Average" }],
            [".", "DatabaseConnections", ".", ".", { stat = "Average", yAxis = "right" }],
            [".", "FreeStorageSpace", ".", ".", { stat = "Minimum", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title  = "Lambdas — invocations & errors",
          region = var.aws_region, view = "timeSeries", period = 60,
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", local.audit_function, { stat = "Sum" }],
            [".", "Errors", ".", ".", { stat = "Sum" }],
            [".", "Invocations", ".", local.contact_function, { stat = "Sum" }],
            [".", "Errors", ".", ".", { stat = "Sum" }],
          ]
        }
      },
    ]
  })
}