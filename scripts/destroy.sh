#!/usr/bin/env bash
# Teardown the llm-proxy infrastructure.
# Order matters: Terraform must be able to read the SSM secrets (data sources) during
# the destroy refresh, so secrets are deleted only AFTER terraform destroy succeeds.
# 1. Destroy all Terraform-managed resources (Lambda, API GW, ECR, IAM, CW, and
#    any SSM params created via create_secrets=true).
# 2. Remove SSM secrets created by hand (the README's `aws ssm put-parameter` step),
#    which Terraform does NOT track and therefore won't delete on destroy.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
SSM_TOGETHER="${TOGETHER_API_KEY_SSM_NAME:-/llm-proxy/${ENVIRONMENT}/TOGETHER_API_KEY}"
SSM_MASTER="${MASTER_KEY_SSM_NAME:-/llm-proxy/${ENVIRONMENT}/LITELLM_MASTER_KEY}"

echo "==> Destroying Terraform-managed resources..."
terraform -chdir=terraform destroy -auto-approve

echo "==> Deleting hand-created SSM secrets (if present)..."
for name in "$SSM_TOGETHER" "$SSM_MASTER"; do
  if aws ssm get-parameter --name "$name" --region "$REGION" &>/dev/null; then
    aws ssm delete-parameter --name "$name" --region "$REGION"
    echo "    deleted $name"
  else
    echo "    not found / already deleted: $name"
  fi
done

echo "Done."