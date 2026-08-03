# Creates an SSM Parameter Store secret from a local value.
# Usage: make sure `SSM_NAME` and `SSM_VALUE` are set first.
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
