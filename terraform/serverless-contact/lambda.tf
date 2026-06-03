# terraform/serverless-contact/lambda.tf

data "archive_file" "contact" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/contact.zip"
}

resource "aws_cloudwatch_log_group" "contact" {
  name              = "/aws/lambda/${var.project}-contact"
  retention_in_days = 7
}

resource "aws_lambda_function" "contact" {
  function_name = "${var.project}-contact"
  role          = aws_iam_role.contact.arn
  runtime       = "python3.12"
  handler       = "lambda_function.lambda_handler"

  filename         = data.archive_file.contact.output_path
  source_code_hash = data.archive_file.contact.output_base64sha256

  timeout     = 10
  memory_size = 256

  environment {
    variables = {
      SENDER_EMAIL    = var.sender_email
      RECIPIENT_EMAIL = var.recipient_email
    }
  }

  depends_on = [aws_cloudwatch_log_group.contact]
}
