# terraform/serverless-audit/iam.tf

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "audit" {
  name               = "${var.project}-audit-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# CloudWatch Logs (every Lambda needs this) — basic execution.
resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.audit.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# X-Ray daemon write — lets the Lambda emit trace segments.
resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.audit.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# Scoped DynamoDB access — only the audit table, only the actions we use.
data "aws_iam_policy_document" "audit_table" {
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:Scan", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.audit.arn]
  }
}

resource "aws_iam_role_policy" "audit_table" {
  name   = "${var.project}-audit-table-rw"
  role   = aws_iam_role.audit.id
  policy = data.aws_iam_policy_document.audit_table.json
}