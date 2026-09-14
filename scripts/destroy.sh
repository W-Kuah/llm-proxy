#!/usr/bin/env bash
# Teardown the llm-proxy infrastructure.
# Order matters: Terraform must be able to read the SSM secrets (data sources) during
# the destroy refresh, so secrets are deleted only AFTER terraform destroy succeeds.
# 1. Destroy all Terraform-managed resources (Lambda, CloudFront, ECR, IAM, CW, and
#    any SSM params created via create_secrets=true).
# 2. Remove SSM secrets created by hand (the README's `aws ssm put-parameter` step),
#    which Terraform does NOT track and therefore won't delete on destroy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
TFVARS="$REPO_ROOT/terraform/terraform.tfvars"

REGION="${AWS_REGION:-$(tfvar "$TFVARS" region us-east-1)}"
ENVIRONMENT="${ENVIRONMENT:-$(tfvar "$TFVARS" environment dev)}"
SSM_TOGETHER="${TOGETHER_API_KEY_SSM_NAME:-/llm-proxy/${ENVIRONMENT}/TOGETHER_API_KEY}"
SSM_MASTER="${MASTER_KEY_SSM_NAME:-/llm-proxy/${ENVIRONMENT}/LITELLM_MASTER_KEY}"
SSM_ADMIN="${ADMIN_KEY_SSM_NAME:-/llm-proxy/${ENVIRONMENT}/ADMIN_KEY}"

echo "==> Destroying Terraform-managed resources..."
terraform -chdir="$REPO_ROOT/terraform" destroy -auto-approve

echo "==> Deleting hand-created SSM secrets (if present)..."
for name in "$SSM_TOGETHER" "$SSM_MASTER" "$SSM_ADMIN"; do
  if aws ssm get-parameter --name "$name" --region "$REGION" &>/dev/null; then
    aws ssm delete-parameter --name "$name" --region "$REGION"
    echo "    deleted $name"
  else
    echo "    not found / already deleted: $name"
  fi
done

echo "Done."
