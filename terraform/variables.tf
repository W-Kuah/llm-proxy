variable "region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g. dev, prod)"
  type        = string
  default     = "dev"
}

variable "name" {
  description = "Base name used for ECR repo, Lambda function, and related resources"
  type        = string
  default     = "llm-proxy"
}

variable "lambda_memory_size" {
  description = "Memory (MB) allocated to the Lambda function"
  type        = number
  default     = 2048
}

variable "lambda_timeout" {
  description = "Timeout (seconds) for the Lambda function"
  type        = number
  default     = 300
}

variable "lambda_architecture" {
  description = "Lambda runtime architecture (arm64 or x86_64)"
  type        = string
  default     = "arm64"
  validation {
    condition     = contains(["arm64", "x86_64"], var.lambda_architecture)
    error_message = "lambda_architecture must be \"arm64\" or \"x86_64\"."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 14
}

variable "image_tag" {
  description = "Tag of the container image to deploy"
  type        = string
  default     = "latest"
}

variable "function_url_auth_type" {
  description = "Auth type for the Lambda function URL (NONE or AWS_IAM)"
  type        = string
  default     = "AWS_IAM"
}

variable "cors_allow_origins" {
  description = "Allowed CORS origins for the function URL and API Gateway"
  type        = list(string)
  default     = ["*"]
}

variable "bedrock_model_ids" {
  description = "Bedrock model IDs to scope the Lambda invoke permission to (must match config.yaml)"
  type        = list(string)
  default     = ["us.anthropic.claude-sonnet-4-5-20250929-v1:0"]
}

variable "together_api_key_ssm_name" {
  description = "SSM Parameter Store name holding the Together AI API key (empty = /llm-proxy/<environment>/TOGETHER_API_KEY)"
  type        = string
  default     = ""
}

variable "master_key_ssm_name" {
  description = "SSM Parameter Store name holding the LiteLLM master key (empty = /llm-proxy/<environment>/LITELLM_MASTER_KEY)"
  type        = string
  default     = ""
}

variable "create_secrets" {
  description = "Whether to create the SSM secrets from local variables (set to true only for bootstrap)"
  type        = bool
  default     = false
}

variable "together_api_key" {
  description = "Together AI API key value (used only when create_secrets is true)"
  type        = string
  default     = ""
}

variable "master_key" {
  description = "LiteLLM master key value (used only when create_secrets is true)"
  type        = string
  default     = ""
}