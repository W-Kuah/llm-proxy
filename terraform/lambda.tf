resource "aws_ecr_repository" "llm_proxy" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

data "aws_ssm_parameter" "together_api_key" {
  name = local.together_api_key_ssm_name
}

data "aws_ssm_parameter" "master_key" {
  name = local.master_key_ssm_name
}

data "aws_ecr_image" "llm_proxy" {
  repository_name = aws_ecr_repository.llm_proxy.name
  image_tag       = var.image_tag
}

resource "aws_lambda_function" "llm_proxy" {
  function_name = var.name
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  architectures = [var.lambda_architecture]
  image_uri     = "${aws_ecr_repository.llm_proxy.repository_url}@${data.aws_ecr_image.llm_proxy.image_digest}"
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout

  environment {
    variables = {
      TOGETHER_API_KEY   = data.aws_ssm_parameter.together_api_key.value
      LITELLM_MASTER_KEY = data.aws_ssm_parameter.master_key.value
      PORT               = "8080"
      AWS_REGION         = var.region
    }
  }
}

resource "aws_lambda_function_url" "llm_proxy" {
  function_name      = aws_lambda_function.llm_proxy.function_name
  authorization_type = var.function_url_auth_type

  cors {
    allow_origins = var.cors_allow_origins
    allow_methods = ["*"]
    allow_headers = ["*"]
  }
}

resource "aws_cloudwatch_log_group" "llm_proxy" {
  name              = "/aws/lambda/${aws_lambda_function.llm_proxy.function_name}"
  retention_in_days = var.log_retention_days
}
