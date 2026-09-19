# S3 bucket to host the frontend static files
resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project_name}-frontend-903467493744"
  tags   = { Name = "${var.project_name}-frontend" }
}

# Enable static website hosting
# This gives us a public URL to access the frontend
resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

# Disable the public access block
# We need public read access for static website hosting
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Bucket policy - allow anyone to read the frontend files
# This is intentional - it is a public website
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  depends_on = [aws_s3_bucket_public_access_block.frontend]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
      }
    ]
  })
}

# Upload index.html to the bucket
locals {
  frontend_content = replace(
    file("${path.root}/frontend/index.html"),
    "__ALB_URL__",
    "http://${var.alb_dns_name}"
  )
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  content      = local.frontend_content
  content_type = "text/html"
  etag         = md5(local.frontend_content)
}
