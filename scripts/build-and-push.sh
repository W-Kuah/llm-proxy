#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
TFVARS="$REPO_ROOT/terraform/terraform.tfvars"

REGION="${AWS_REGION:-$(tfvar "$TFVARS" region us-east-1)}"
ECR_REPO="${ECR_REPO:-$(tfvar "$TFVARS" name llm-proxy)}"
IMAGE_TAG="${IMAGE_TAG:-$(tfvar "$TFVARS" image_tag latest)}"

# Match the Lambda architecture in terraform.tfvars.
case "$(tfvar "$TFVARS" lambda_architecture arm64)" in
  x86_64) PLATFORM="${PLATFORM:-linux/amd64}" ;;
  *)      PLATFORM="${PLATFORM:-linux/arm64}" ;;
esac

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE="${REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

docker build --platform "$PLATFORM" --provenance=false --sbom=false -t "$IMAGE" "$REPO_ROOT"
docker push "$IMAGE"

echo "Pushed $IMAGE"
