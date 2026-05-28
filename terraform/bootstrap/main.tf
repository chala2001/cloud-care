# ---------------------------------------------------------------------------
# S3 bucket that will hold Terraform state for ALL phases of this project.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  # Safety net: refuse to destroy this bucket by accident. State buckets should
  # outlive everything else. To intentionally remove it, you'd edit this first.
  lifecycle {
    prevent_destroy = true
  }
}

# Keep every version of the state file (lets you roll back a bad apply).
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest with AWS-managed keys (SSE-S3). State can contain
# secrets (DB passwords), so this is non-negotiable.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block ALL public access to the bucket. State must never be public.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# DynamoDB table used as a distributed LOCK so two `terraform apply` runs can't
# write state at the same time. Terraform expects a primary key named "LockID".
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "tf_locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST" # on-demand: you pay per request, ~free at our scale
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S" # String
  }
}