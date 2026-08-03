resource "aws_apigatewayv2_api" "llm_proxy" {
  name          = "${var.name}-http-api"
  description   = "HTTP API for the LLM proxy"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.cors_allow_origins
    allow_methods = ["*"]
    allow_headers = ["*"]
  }
}

resource "aws_apigatewayv2_integration" "llm_proxy" {
  api_id                 = aws_apigatewayv2_api.llm_proxy.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.llm_proxy.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "llm_proxy" {
  api_id    = aws_apigatewayv2_api.llm_proxy.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.llm_proxy.id}"
}

resource "aws_apigatewayv2_stage" "llm_proxy" {
  api_id      = aws_apigatewayv2_api.llm_proxy.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "llm_proxy_apigw" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.llm_proxy.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.llm_proxy.execution_arn}/*/*"
}