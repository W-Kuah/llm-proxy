#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS="$REPO_ROOT/terraform/terraform.tfvars"

# Read a simple `key = "value"` from terraform.tfvars (single source of truth),
# falling back to a default. Env vars passed in still take precedence below.
tfvar() {
  local key="$1" default="$2" val=""
  if [[ -f "$TFVARS" ]]; then
    val="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*$/\1/')"
  fi
  printf '%s' "${val:-$default}"
}

REGION="${AWS_REGION:-$(tfvar region us-east-1)}"
ECR_REPO="${ECR_REPO:-$(tfvar name llm-proxy)}"
IMAGE_TAG="${IMAGE_TAG:-$(tfvar image_tag latest)}"

# Match the Lambda architecture in terraform.tfvars.
case "$(tfvar lambda_architecture arm64)" in
  x86_64) PLATFORM="${PLATFORM:-linux/amd64}" ;;
  *)      PLATFORM="${PLATFORM:-linux/arm64}" ;;
esac

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE="${REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

docker build --platform "$PLATFORM" --provenance=false --sbom=false -t "$IMAGE" .
docker push "$IMAGE"

echo "Pushed $IMAGE"
