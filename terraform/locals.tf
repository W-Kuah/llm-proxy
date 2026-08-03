locals {
  # Resolve SSM secret names, defaulting to an environment-scoped path so dev,
  # staging, and prod secrets don't collide.
  together_api_key_ssm_name = var.together_api_key_ssm_name != "" ? var.together_api_key_ssm_name : "/llm-proxy/${var.environment}/TOGETHER_API_KEY"
  master_key_ssm_name       = var.master_key_ssm_name != "" ? var.master_key_ssm_name : "/llm-proxy/${var.environment}/LITELLM_MASTER_KEY"
}