# Bootstrap secrets from local values for the first deploy. Controlled by
# create_secrets=true in terraform.tfvars — use once, then set back to false.
resource "aws_ssm_parameter" "together_api_key" {
  count = var.create_secrets ? 1 : 0
  name  = local.together_api_key_ssm_name
  type  = "SecureString"
  value = var.together_api_key
}

resource "aws_ssm_parameter" "master_key" {
  count = var.create_secrets ? 1 : 0
  name  = local.master_key_ssm_name
  type  = "SecureString"
  value = var.master_key
}
