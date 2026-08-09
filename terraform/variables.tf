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
  default     = 1
}

variable "image_tag" {
  description = "Tag of the container image to deploy"
  type        = string
  default     = "latest"
}

variable "function_url_auth_type" {
  description = "Auth type for the Lambda function URL. Must be NONE so the origin accepts the viewer's Bearer token; auth happens at the app layer (LiteLLM master key). AWS_IAM is incompatible with OAC signing_behavior = no-override."
  type        = string
  default     = "NONE"
}

variable "cloudfront_price_class" {
  description = "Price class for the CloudFront distribution (PriceClass_100, PriceClass_200, or PriceClass_All). Australia/NZ and South America are only served by PriceClass_All."
  type        = string
  default     = "PriceClass_All"
}

variable "cors_allow_origins" {
  description = "Allowed CORS origins for the function URL"
  type        = list(string)
  default     = ["*"]
}

variable "config_path" {
  description = "Path to the LiteLLM config.yaml that defines the model list (relative to the terraform working directory)"
  type        = string
  default     = "../config.yaml"
}

variable "bedrock_model_ids" {
  description = "Extra Bedrock model IDs to scope the Lambda invoke permission to, in addition to those derived from config.yaml"
  type        = list(string)
  default     = []
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