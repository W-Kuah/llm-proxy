output "repository_url" {
  description = "ECR repository URL for the llm-proxy image"
  value       = aws_ecr_repository.llm_proxy.repository_url
}

output "lambda_function_name" {
  description = "Name of the deployed Lambda function"
  value       = aws_lambda_function.llm_proxy.function_name
}

output "function_url" {
  description = "Lambda Function URL endpoint for the proxy (origin of the CloudFront distribution)"
  value       = aws_lambda_function_url.llm_proxy.function_url
}

output "cloudfront_url" {
  description = "CloudFront endpoint for the proxy; this is the OpenAI-compatible base URL"
  value       = "https://${aws_cloudfront_distribution.llm_proxy.domain_name}"
}
