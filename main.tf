terraform {
  backend "s3" {
    bucket = "afunderburg-development-terraform-state"
    key    = "react-cors-spa/terraform.tfstate"
    region = "us-east-2"

    dynamodb_table = "afunderburg-development-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region  = "us-east-2"
  default_tags {
    tags = {
      environment   = "demo"
      deployed_with = "terraform"
      project       = local.project_name
      org           = "afunderburg_development"
      github_owner  = "agfunderburg10"
      github_repo   = local.project_name
    }
  }
}

provider "aws" {
  alias   = "use1"
  region  = "us-east-1"
}

data "aws_region" "current" {}

locals {
  project_name          = "react-cors-spa"
  s3_origin_id          = "s3-content-origin"
  api_gateway_origin_id = "api-gateway-origin"

  subdomain = "demo-spa-tf"
  domain    = "afunderburg.com"

  common_logs_bucket = "afunderburg-development-common-logs"
}

resource "aws_api_gateway_rest_api" "main" {
  name = "${local.project_name}-terraform"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "hello"
}

resource "aws_api_gateway_method" "hello_get" {
  rest_api_id      = aws_api_gateway_rest_api.main.id
  resource_id      = aws_api_gateway_resource.main.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "hello_get_200" {
  rest_api_id          = aws_api_gateway_rest_api.main.id
  resource_id          = aws_api_gateway_resource.main.id
  http_method          = aws_api_gateway_method.hello_get.http_method
  type                 = "MOCK"
  passthrough_behavior = "WHEN_NO_MATCH"
  request_templates = {
    "application/json" = jsonencode(
      {
        "statusCode" : 200
      }
    )
  }
}

resource "aws_api_gateway_integration_response" "hello_get_200" {
  rest_api_id       = aws_api_gateway_rest_api.main.id
  resource_id       = aws_api_gateway_resource.main.id
  http_method       = aws_api_gateway_method.hello_get.http_method
  status_code       = aws_api_gateway_method_response.response_200.status_code
  selection_pattern = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }

  response_templates = {
    "application/json" = jsonencode(
      {
        "message" : "Deployed using Terraform!"
      }
    )
  }
}

resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.main.id
  http_method = aws_api_gateway_method.hello_get.http_method
  status_code = "200"
  response_models = {
    "application/json" : "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = "v1"

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_api_gateway_integration_response.hello_get_200]
}

resource "aws_s3_bucket" "content" {
  bucket = "${local.project_name}-${aws_api_gateway_rest_api.main.id}"
}

resource "aws_s3_bucket_public_access_block" "content" {
  bucket = aws_s3_bucket.content.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "content" {
  bucket = aws_s3_bucket.content.id

  target_bucket = "afunderburg-development-common-logs"
  target_prefix = "s3-access-logs"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "content" {
  bucket = aws_s3_bucket.content.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "allow_cloudfront_access" {
  bucket = aws_s3_bucket.content.id
  policy = data.aws_iam_policy_document.allow_cloudfront_access.json
}

data "aws_iam_policy_document" "allow_cloudfront_access" {
  statement {
    sid = "PolicyForCloudFrontPrivateContent"
    actions = [
      "s3:GetObject*"
    ]

    resources = [
      "${aws_s3_bucket.content.arn}/*",
    ]

    principals {
      type = "Service"
      identifiers = [
        "cloudfront.amazonaws.com"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values = [
        aws_cloudfront_distribution.main.arn
      ]
    }
  }
}

data "aws_route53_zone" "main" {
  name = local.domain
}

data "aws_acm_certificate" "main" {
  # CloudFront requires ACM cert in us-east-1
  provider = aws.use1
  domain   = "*.${local.domain}"
}

resource "aws_route53_record" "main" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${local.subdomain}.${data.aws_route53_zone.main.name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = true
  }
}

resource "aws_cloudfront_origin_access_control" "main" {
  name                              = "${local.project_name}-terraform"
  description                       = "Default Origin Access Control"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "main" {
  # S3 origin
  origin {
    domain_name              = aws_s3_bucket.content.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.main.id
    origin_id                = local.s3_origin_id
  }

  # APIGateway origin
  origin {
    domain_name = "${aws_api_gateway_rest_api.main.id}.execute-api.${data.aws_region.current.name}.amazonaws.com"
    origin_id   = local.api_gateway_origin_id
    custom_origin_config {
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      http_port              = 80
      https_port             = 443
    }
  }

  aliases = ["${local.subdomain}.${local.domain}"]

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    # Use managed cache policies - https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    origin_request_policy_id   = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # CORS-S3Origin
    response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03" # SecurityHeadersPolicy 

    viewer_protocol_policy = "redirect-to-https"
  }

  # Cache behavior with precedence 0
  ordered_cache_behavior {
    path_pattern     = "/v1/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = local.api_gateway_origin_id

    # Use managed cache policies - https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html
    cache_policy_id            = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id   = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
    response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03" # SecurityHeadersPolicy

    viewer_protocol_policy = "redirect-to-https"
  }

  # Cache behavior with precedence 1
  # Never cache index.html for immediate invalidation on deployment
  ordered_cache_behavior {
    path_pattern     = "/index.html"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = local.s3_origin_id

    # Use managed cache policies - https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html
    cache_policy_id            = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id   = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
    response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03" # SecurityHeadersPolicy

    viewer_protocol_policy = "redirect-to-https"
  }

  price_class = "PriceClass_All"

  logging_config {
    include_cookies = false
    bucket          = "${local.common_logs_bucket}.s3.amazonaws.com"
    prefix          = "cloudfront-access-logs/${local.project_name}-terraform"
  }

  # aliases = ["mysite.example.com", "yoursite.example.com"]

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US", "CA", "GB", "DE"]
    }
  }

  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.main.arn
    minimum_protocol_version = "TLSv1.2_2021"
    ssl_support_method       = "sni-only"
  }
}

output "api_endpoint" {
  value = aws_api_gateway_deployment.main.invoke_url
}

output "content_bucket" {
  value = aws_s3_bucket.content.id
}
