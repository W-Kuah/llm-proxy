data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda" {
  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:InvokeInferenceProfile",
      "bedrock:InvokeInferenceProfileWithResponseStream",
    ]
    resources = concat(
      # Build foundation-model and inference-profile ARNs from the shared model list.
      [for id in local.bedrock_model_ids : "arn:aws:bedrock:*:*:foundation-model/${id}"],
      [for id in local.bedrock_model_ids : "arn:aws:bedrock:*:*:inference-profile/${id}"],
      # Also allow the regional variant without the cross-region inference-profile
      # prefix (e.g. anthropic.claude-sonnet-...), which LiteLLM may invoke directly.
      [for id in local.bedrock_model_ids : "arn:aws:bedrock:*:*:foundation-model/${replace(replace(replace(replace(replace(id, "global.", ""), "apac.", ""), "eu.", ""), "au.", ""), "us.", "")}"],
    )
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [aws_ecr_repository.llm_proxy.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.name}-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}
