# terraform/serverless-audit/lambda.tf

# Build the deployment zip from src/. Re-runs when the .py file changes.
data "archive_file" "audit" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/audit.zip"
}

# Pre-create the log group so we control retention (else AWS auto-creates one
# with "never expire" — silently piling up data forever).
resource "aws_cloudwatch_log_group" "audit" {
  name              = "/aws/lambda/${var.project}-audit"
  retention_in_days = 7
}

resource "aws_lambda_function" "audit" {
  function_name = "${var.project}-audit"
  role          = aws_iam_role.audit.arn
  runtime       = "python3.12"
  handler       = "lambda_function.lambda_handler"

  filename         = data.archive_file.audit.output_path
  source_code_hash = data.archive_file.audit.output_base64sha256

  timeout     = 10
  memory_size = 256

  tracing_config {
    mode = "Active" # X-Ray on
  }

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.audit.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.audit]
}