# CloudFront front-door for the Lambda Function URL.
#
# Why not API Gateway? API Gateway caps an integration at 30s and buffers the
# full response, which breaks long tool-call generations and SSE streaming.
# CloudFront + Function URL adds no per-request charge, has no integration
# timeout wall, and natively streams (time to first byte = first token).

resource "aws_cloudfront_origin_access_control" "llm_proxy" {
  name                              = "${var.name}-oac"
  description                       = "OAC for the llm-proxy Lambda Function URL origin"
  origin_access_control_origin_type = "lambda"
  # no-override: if the viewer already sends an Authorization header (our LiteLLM
  # Bearer master key), CloudFront passes it through untouched; otherwise it signs
  # with SigV4. "always" would overwrite the Bearer token and break the proxy auth.
  signing_behavior = "no-override"
  signing_protocol = "sigv4"
}

# Use the AWS-managed policies here — do NOT substitute custom ones built from
# TTL+headers:
# * Cache policy: managed CachingDisabled ("4135ea2d-6df8-44a3-9df3-4b5a84be39ad").
#   Caching must be disabled (every request is a unique LLM inference), but the
#   OAC API rejects whitelisting any header in a caching-disabled policy.
# * Origin request policy: managed AllViewerExceptHostHeader
#   ("b689b0a8-53d0-40ab-baf2-68738e2966ac"). CloudFront only forwards the viewer
#   Authorization header for OAC no-override when a policy forwards ALL headers
#   except Host — it cannot be forwarded individually. Host must NOT be forwarded
#   to a Lambda function URL (it 403s); CF sets Host to the origin domain instead.

resource "aws_cloudfront_distribution" "llm_proxy" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "Front-door for the llm-proxy gateway (LiteLLM on Lambda)"

  # No custom domain yet: the default *.cloudfront.net URL serves HTTPS for free.
  # Later: add ACM + aliases + Route 53 records here.

  origin {
    origin_id                = aws_lambda_function.llm_proxy.function_name
    domain_name              = replace(trimprefix(aws_lambda_function_url.llm_proxy.function_url, "https://"), "/", "")
    origin_access_control_id = aws_cloudfront_origin_access_control.llm_proxy.id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      # Default CloudFront origin read timeout is 30s — too short for slow
      # first-token models like kimi-k3. Max for custom HTTP origins is 60s.
      # Once the first byte streams in the timeout resets per-read.
      origin_read_timeout = 60
    }
  }

  default_cache_behavior {
    target_origin_id       = aws_lambda_function.llm_proxy.function_name
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = false

    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed: CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # Managed: AllViewerExceptHostHeader
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Default CloudFront cert; no custom viewer certificate yet.
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  price_class = var.cloudfront_price_class
}

# Function URL auth type is NONE (see lambda.tf): CloudFront fronts the gateway but
# the real auth boundary is the LiteLLM master key at the app layer (the Phase-0
# single-shared-key model). With auth NONE, Lambda still requires a resource-based
# policy that publicly grants BOTH lambda:InvokeFunctionUrl and lambda:InvokeFunction
# (required for ALL function URLs since Oct 2025) — without it the function URL
# returns 403 Forbidden even for unauthenticated public access.
resource "aws_lambda_permission" "llm_proxy_public_url" {
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.llm_proxy.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "llm_proxy_public_invoke" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.llm_proxy.function_name
  principal     = "*"
  # AWS recommends scoping this grant to function-URL calls via the
  # lambda:InvokedViaFunctionUrl condition, but the aws_lambda_permission
  # resource (v5 provider) exposes no way to set that condition — no generic
  # "condition" block and no argument for the key. So the grant is "*", matching
  # the public NONE-auth function URL above. The real auth boundary is the
  # LiteLLM master key at the app layer (the Phase-0 single-shared-key model).
}