# terraform/serverless-audit/apigw.tf

# HTTP API is the newer, cheaper, simpler API Gateway flavor. Use it unless you
# need a feature only REST API has (e.g. resource policies, usage plans, WAF).
resource "aws_apigatewayv2_api" "audit" {
  name          = "${var.project}-audit-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"] # tighten to your CloudFront origin in production
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
  }
}

# Tell API Gateway how to invoke the Lambda. AWS_PROXY = pass the raw HTTP
# request to Lambda; payload format 2.0 = the modern, slimmer event shape.
resource "aws_apigatewayv2_integration" "audit" {
  api_id                 = aws_apigatewayv2_api.audit.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.audit.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_events" {
  api_id    = aws_apigatewayv2_api.audit.id
  route_key = "POST /events"
  target    = "integrations/${aws_apigatewayv2_integration.audit.id}"
}

resource "aws_apigatewayv2_route" "get_events" {
  api_id    = aws_apigatewayv2_api.audit.id
  route_key = "GET /events"
  target    = "integrations/${aws_apigatewayv2_integration.audit.id}"
}

# A stage publishes the API at a URL. "$default" + auto_deploy = changes go live
# on every apply, no manual deployment step needed.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.audit.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = 50
    throttling_rate_limit    = 100
  }
}

# Permission: explicitly let THIS API invoke THIS Lambda (Lambda is locked down
# by default, so without this you'd get 500s with "not authorized to invoke").
resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGwInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.audit.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.audit.execution_arn}/*/*"
}