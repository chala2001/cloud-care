# terraform/serverless-contact/ses.tf

# Each email identity must be confirmed by clicking a link AWS sends — Terraform
# can create the identity, but only you can verify it.
resource "aws_sesv2_email_identity" "sender" {
  email_identity = var.sender_email
}

resource "aws_sesv2_email_identity" "recipient" {
  # If sender == recipient, this still creates a second identity entry pointing
  # at the same address (idempotent). It's harmless and keeps the dependency
  # graph clean.
  email_identity = var.recipient_email
}