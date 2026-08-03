#!/usr/bin/env bash
# Teardown the llm-proxy infrastructure.
# Order matters: Terraform must be able to read the SSM secrets (data sources) during
# the destroy refresh, so secrets are deleted only AFTER terraform destroy succeeds.
# 1. Destroy all Terraform-managed resources (Lambda, API GW, ECR, IAM, CW, and
#    any SSM params created via create_secrets=true).
# 2. Remove SSM secrets created by hand (the README's `aws ssm put-parameter` step),
#    which Terraform does NOT track and therefore won't delete on destroy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS="$REPO_ROOT/terraform/terraform.tfvars"

# Read a simple `key = "value"` from terraform.tfvars (single source of truth).
tfvar() {
  local key="$1" default="$2" val=""
  if [[ -f "$TFVARS" ]]; then
    val="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*$/\1/')"
  fi
  printf '%s' "${val:-$default}"
}

REGION="${AWS_REGION:-$(tfvar region us-east-1)}"
ENVIRONMENT="${ENVIRONMENT:-$(tfvar environment dev)}"
SSM_TOGETHER="${TOGETHER_API_KEY_SSM_NAME:-/llm-proxy/${ENVIRONMENT}/TOGETHER_API_KEY}"
SSM_MASTER="${MASTER_KEY_SSM_NAME:-/llm-proxy/${ENVIRONMENT}/LITELLM_MASTER_KEY}"

echo "==> Destroying Terraform-managed resources..."
terraform -chdir="$REPO_ROOT/terraform" destroy -auto-approve

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
