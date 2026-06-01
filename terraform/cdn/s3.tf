# terraform/cdn/s3.tf

# Bucket names are globally unique — suffix with the account id.
resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project}-frontend-${data.aws_caller_identity.current.account_id}"

  # Learning: allow `terraform destroy` even when objects exist.
  force_destroy = true

  tags = { Name = "${var.project}-frontend" }
}

# Versioning lets us roll a bad build back by republishing the previous object.
resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt objects at rest (no-cost, just good hygiene).
resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block ALL public access. CloudFront will reach the bucket PRIVATELY via OAC.
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}