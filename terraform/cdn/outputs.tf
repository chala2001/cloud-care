# terraform/cdn/outputs.tf

output "cloudfront_domain_name" {
  description = "Public domain — open this in a browser"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "cloudfront_distribution_id" {
  description = "Distribution id (used to invalidate the cache after a deploy)"
  value       = aws_cloudfront_distribution.main.id
}

output "frontend_bucket" {
  description = "S3 bucket name — upload the React `dist/` here"
  value       = aws_s3_bucket.frontend.id
}