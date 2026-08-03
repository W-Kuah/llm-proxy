output "repository_url" {
  description = "ECR repository URL for the llm-proxy image"
  value       = aws_ecr_repository.llm_proxy.repository_url
}

output "lambda_function_name" {
  description = "Name of the deployed Lambda function"
  value       = aws_lambda_function.llm_proxy.function_name
}

output "function_url" {
  description = "Lambda Function URL endpoint for the proxy"
  value       = aws_lambda_function_url.llm_proxy.function_url
}

output "api_gateway_url" {
  description = "API Gateway HTTP API endpoint for the proxy"
  value       = aws_apigatewayv2_stage.llm_proxy.invoke_url
}
