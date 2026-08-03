locals {
  # Resolve SSM secret names, defaulting to an environment-scoped path so dev,
  # staging, and prod secrets don't collide.
  together_api_key_ssm_name = var.together_api_key_ssm_name != "" ? var.together_api_key_ssm_name : "/llm-proxy/${var.environment}/TOGETHER_API_KEY"
  master_key_ssm_name       = var.master_key_ssm_name != "" ? var.master_key_ssm_name : "/llm-proxy/${var.environment}/LITELLM_MASTER_KEY"

  # Single source of truth: config.yaml defines the model list. Derive the
  # Bedrock IDs from it so adding a model doesn't require a separate tfvars change.
  config = yamldecode(file(var.config_path))

  # Keep var.bedrock_model_ids as an additive override for models not in config.yaml.
  bedrock_model_ids = concat(
    var.bedrock_model_ids,
    [for m in local.config.model_list : trimprefix(m.litellm_params.model, "bedrock/") if startswith(m.litellm_params.model, "bedrock/")],
  )
}