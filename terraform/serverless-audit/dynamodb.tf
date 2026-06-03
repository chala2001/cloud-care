# terraform/serverless-audit/dynamodb.tf

resource "aws_dynamodb_table" "audit" {
  name         = "${var.project}-audit"
  billing_mode = "PAY_PER_REQUEST" # on-demand → pay per request, ~free at our scale
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  # Point-in-time recovery is free for the first 35 days of restore window and
  # is a one-line safety net you should default to.
  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = "${var.project}-audit" }
}