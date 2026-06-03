# terraform/serverless-contact/iam.tf

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "contact" {
  name               = "${var.project}-contact-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.contact.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ses:SendEmail, scoped to the SENDER identity ARN, AND a condition restricting
# the FromAddress to our exact sender — belt and braces.
data "aws_iam_policy_document" "send_email" {
  statement {
    actions = ["ses:SendEmail"]
    # When the recipient address is ALSO a verified identity in this account,
    # SES checks ses:SendEmail against BOTH the sender's and the recipient's
    # identity ARN. So we list both. The FromAddress condition below still
    # restricts the role to sending *as* the sender only.
    resources = [
      aws_sesv2_email_identity.sender.arn,
      aws_sesv2_email_identity.recipient.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.sender_email]
    }
  }
}

resource "aws_iam_role_policy" "send_email" {
  name   = "${var.project}-send-email"
  role   = aws_iam_role.contact.id
  policy = data.aws_iam_policy_document.send_email.json
}