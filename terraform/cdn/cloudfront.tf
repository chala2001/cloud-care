# terraform/cdn/cloudfront.tf

# OAC is the modern replacement for the legacy Origin Access Identity (OAI).
# It signs CloudFront's requests to S3 with SigV4, scoped to this distribution.
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project}-frontend-oac"
  description                       = "OAC for the CloudCare frontend bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudCare CDN"
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # cheapest: US/CA/EU edges only (plenty for learning)

  # --- ORIGIN 1: the private S3 bucket (static React build) ---
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # --- ORIGIN 2: the ALB from the compute stack (API) ---
  origin {
    domain_name = data.terraform_remote_state.compute.outputs.alb_dns_name
    origin_id   = "alb-api"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # ALB has no TLS cert yet
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # --- DEFAULT BEHAVIOR: cache the React app aggressively from S3 ---
  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https" # any http request → https
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS-managed policy: CachingOptimized (long TTLs, gzip, brotli).
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # --- /api/* BEHAVIOR: forward dynamically to the ALB, never cache ---
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "alb-api"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS-managed policies:
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer (forward headers/qs/cookies)
  }

  # SPA fallback: an unknown URL (e.g. /patients/42) hits S3, gets 403/404
  # because the file doesn't exist. Serve index.html instead so React Router
  # (or any client-side routing you add) can handle the path.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  # Free *.cloudfront.net certificate. To attach a custom domain later, replace
  # this with an `acm_certificate_arn` (the cert MUST be in us-east-1).
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${var.project}-cdn" }
}
