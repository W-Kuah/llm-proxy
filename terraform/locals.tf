locals {
  # Resolve SSM secret names, defaulting to an environment-scoped path so dev,
  # staging, and prod secrets don't collide.
  together_api_key_ssm_name = var.together_api_key_ssm_name != "" ? var.together_api_key_ssm_name : "/llm-proxy/${var.environment}/TOGETHER_API_KEY"
  master_key_ssm_name       = var.master_key_ssm_name != "" ? var.master_key_ssm_name : "/llm-proxy/${var.environment}/LITELLM_MASTER_KEY"
  admin_key_ssm_name        = var.admin_key_ssm_name != "" ? var.admin_key_ssm_name : "/llm-proxy/${var.environment}/ADMIN_KEY"

  # The model catalog is runtime-managed (DynamoDB), so Bedrock IAM is wildcarded
  # (see iam.tf) and config.yaml is no longer parsed here — it's a seed only.
  models_table_name = "${var.name}-models"
}