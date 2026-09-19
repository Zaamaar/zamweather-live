# Origin Access Control
# Allows CloudFront to access the S3 bucket privately
# S3 bucket stays completely private - only CloudFront can read it
resource "aws_cloudfront_origin_access_control" "main" {
  name                              = "${var.project_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "main" {

  enabled             = true
  default_root_object = "index.html"
  comment             = "${var.project_name} distribution"

  # Origin 1 - S3 bucket (serves the frontend)
  origin {
    domain_name              = var.bucket_regional_domain
    origin_id                = "S3Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.main.id
  }

  # Origin 2 - ALB (serves the Flask API)
  origin {
    domain_name = var.alb_dns_name
    origin_id   = "ALBOrigin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Default behaviour - serve frontend from S3
  # Matches all requests that don't match other behaviours
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3Origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  # API behaviour - forward /api/* requests to ALB
  # This is path-based routing at the CloudFront level
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "ALBOrigin"
    viewer_protocol_policy = "redirect-to-https"

    # Do not cache API responses
    # Weather data should always be fresh
    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${var.project_name}-distribution" }
}

# S3 bucket policy - allows CloudFront OAC to read from the bucket
# Without this policy CloudFront cannot access the S3 files
resource "aws_s3_bucket_policy" "frontend" {
  bucket = var.bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${var.bucket_arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.main.arn
          }
        }
      }
    ]
  })
}
