# llm-proxy

A thin LLM API gateway built on [LiteLLM](https://github.com/BerriAI/litellm) that
exposes multiple model providers behind a single OpenAI-compatible endpoint,
deployed as an AWS Lambda container.

## Table of Contents

- [Overview](#overview)
- [Quick start (Docker)](#quick-start-docker)
- [Configuration](#configuration)
- [Running locally](#running-locally)
- [Deployment (Terraform)](#deployment-terraform)
- [Operational notes](#operational-notes)

## Overview

- Routes requests to Claude and Kimi (Amazon Bedrock) and Llama 3, DeepSeek, GLM (Together AI)
- Provides one consistent OpenAI-compatible API surface
- Runs as a serverless container on AWS Lambda (via the AWS Lambda Adapter)

## Quick start (Docker)

```bash
docker build -t llm-proxy .
docker run --rm -p 8080:8080 \
  --env-file .env \
  -e AWS_PROFILE=default \
  -v ~/.aws:/root/.aws:ro \
  llm-proxy
curl http://localhost:8080/v1/models
```

Prereqs: Docker, a `.env` with your keys (see [Environment variables](#environment-variables)), and AWS creds for the Bedrock route.

## Configuration

### Model routing (`config.yaml`)

| Model name          | Provider       | Backend model                                              |
| ------------------- | -------------- | ---------------------------------------------------------- |
| `claude-sonnet`     | Amazon Bedrock | `global.anthropic.claude-sonnet-4-5-20250929-v1:0` (cross-region `global.` inference profile) |
| `kimi-k2.5`         | Amazon Bedrock | `moonshotai.kimi-k2.5`                                    |
| `kimi-k2-thinking`  | Amazon Bedrock | `moonshot.kimi-k2-thinking`                              |
| `glm-5`             | Amazon Bedrock | `zai.glm-5`                                               |
| `llama3-8bq`        | Together AI    | `meta-llama/Llama-3.3-70B-Instruct-Turbo`                |
| `kimi-k3`           | Together AI    | `moonshotai/Kimi-K3`                                     |
| `deepseek-v4`       | Together AI    | `deepseek-ai/DeepSeek-V4-Pro`                            |
| `glm-5.2`           | Together AI    | `zai-org/GLM-5.2`                                        |

The **provider prefix** in `litellm_params.model` (before the first `/`) tells
LiteLLM how to route and tells Terraform whether IAM changes are needed:

| Provider            | Prefix        | IAM change?                       | API key                    |
| ------------------- | ------------- | --------------------------------- | -------------------------- |
| Amazon Bedrock      | `bedrock/`    | Yes — auto-scoped to the role     | none (Lambda's IAM role)   |
| Together AI         | `together_ai/`| No                                | `TOGETHER_API_KEY` (shared)|
| Any other provider  | e.g. `openai/`| No                                | needs its own env key      |

### Adding a model

**Bedrock — edit `config.yaml` only:**

```yaml
- model_name: my-claude
  litellm_params:
    model: bedrock/global.anthropic.claude-sonnet-...-v1:0
    aws_region_name: os.environ/AWS_REGION   # only if it differs from the deploy region
```

No key in config — the Lambda's IAM role authenticates. Terraform parses
`config.yaml` (`terraform/locals.tf`) and scopes the role to every `bedrock/`-
prefixed model automatically, so nothing else changes.

**Together AI — edit `config.yaml` only:**

```yaml
- model_name: my-llama
  litellm_params:
    model: together_ai/meta-llama/Llama-3.3-70B-Instruct-Turbo
    api_key: os.environ/TOGETHER_API_KEY
```

Uses the shared `TOGETHER_API_KEY` (already wired SSM → Lambda env). No IAM or
`terraform.tfvars` change.

**Any other provider — three changes** (each provider gets its own key):

1. `config.yaml` with that provider's prefix and a key reference, e.g. `model: openai/gpt-4o`, `api_key: os.environ/OPENAI_API_KEY`
2. SSM Parameter Store: store `OPENAI_API_KEY` (same `/llm-proxy/<env>/...` pattern)
3. `terraform/lambda.tf`: add an `aws_ssm_parameter` data source and pass `OPENAI_API_KEY` into the Lambda `environment`, then `terraform apply`

Then rebuild + redeploy (`./scripts/build-and-push.sh`, `terraform apply`), or just
restart the local container for a local-only test. The new model is immediately
available at `/v1/chat/completions`; check `/v1/models`.

### Environment variables

| Variable             | Purpose                                        |
| -------------------- | ---------------------------------------------- |
| `TOGETHER_API_KEY`   | API key for Together AI                        |
| `LITELLM_MASTER_KEY` | Master key for LiteLLM (`general_settings`)    |
| `AWS_REGION`         | Region for Bedrock (uses credentials from IAM) |
| `ENVIRONMENT`        | Optional. Basename for SSM secret paths (`/llm-proxy/<env>/...`); must match Terraform's `environment` var |

Create a `.env` file with your keys (gitignored, safe to keep locally):

```bash
cp .env.example .env
```



All four are read from the environment at runtime. `ENVIRONMENT` is used as the
default basename for SSM secret paths (`/llm-proxy/<env>/...`) — keep it in sync
with Terraform's `environment` var.

## Running locally

### Docker (recommended)

```bash
docker build -t llm-proxy .
docker run --rm -p 8080:8080 \
  --env-file .env \
  -e AWS_PROFILE=default \
  -v ~/.aws:/root/.aws:ro \
  llm-proxy
```

- `--env-file .env` loads `TOGETHER_API_KEY`, `LITELLM_MASTER_KEY`, `AWS_REGION`.
- `-v ~/.aws:/root/.aws:ro` mounts your AWS credentials so the Bedrock routes can authenticate.
- With **SSO** credentials the container can't auto-pick a profile, so set `AWS_PROFILE` to the profile name in `~/.aws/config` (e.g. `defaultAdmin`). The first Bedrock request can take minutes while SSO creds initialize.

> Verified: both `llama3-8bq` (Together) and `claude-sonnet` (Bedrock) return completions this way.

### pip (no Docker)

```bash
pip install "litellm[proxy]"
set -a && source .env && set +a
litellm --config config.yaml --port 8080
```

Call a model:

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-sonnet", "messages": [{"role": "user", "content": "Hello"}]}'
```

> The `claude-sonnet` route calls Bedrock, so it needs valid AWS credentials in
> your shell; Together routes use the `TOGETHER_API_KEY` from `.env`.

## Deployment (Terraform)

Infrastructure is defined as code in `terraform/`:

| Resource                      | Description                                    |
| ----------------------------- | ---------------------------------------------- |
| ECR repository                | Stores the `llm-proxy` container image         |
| IAM role + policies           | Lambda execution, Bedrock invoke, ECR pull     |
| Lambda function               | Container image, arm64, 2048 MB, 300 s timeout (configurable) |
| Lambda function URL           | Public HTTPS endpoint (if `enable_function_url = true`) |
| API Gateway (HTTP API)        | Public HTTPS endpoint (always created)                   |
| CloudWatch log group          | Logs, 14-day retention (configurable)          |
| SSM Parameter Store (optional)| SecureString keys for `TOGETHER_API_KEY`, `LITELLM_MASTER_KEY` |

### Prerequisites

- Terraform >= 1.5
- AWS credentials with permissions for ECR, Lambda, IAM, SSM, CloudWatch
- Docker (for the build script); for local-only runs Docker **or** Python 3.9+ with `pip install "litellm[proxy]"`
- The AWS CLI with a configured profile

#### AWS access (SSO)

```bash
aws sso login --sso-session default     # or: aws configure sso to create one
export AWS_PROFILE=defaultAdmin         # the profile name in ~/.aws/config
```

Terraform and the AWS CLI use whatever profile is exported in your shell. For the
**local Docker run** the profile must also be passed into the container
(`-e AWS_PROFILE=<profile>`); it can't auto-pick one.

### 1. Configure

Alongside `.env`, deployment is customized via `terraform.tfvars` (gitignored).
Start from the example and set `environment`, `name`, and any tuning:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Key options (full list in the example file):

| Variable                 | Default            | Meaning                                  |
| ------------------------ | ------------------ | ---------------------------------------- |
| `region`                 | `us-east-1`        | AWS region for all resources + Lambda's `AWS_REGION` |
| `environment`            | `dev`              | Baked into SSM secret paths (`/llm-proxy/<env>/...`) |
| `name`                   | `llm-proxy`        | Base name for Lambda/ECR/IAM/API GW resources |
| `image_tag`              | `latest`           | ECR tag to deploy; read by `build-and-push.sh` |
| `lambda_memory_size`     | `2048`             | Lambda memory in MB                     |
| `lambda_timeout`         | `300`              | Lambda timeout in seconds               |
| `lambda_architecture`    | `arm64`            | `arm64` or `x86_64`                     |
| `log_retention_days`     | `14`               | CloudWatch retention                    |
| `cors_allow_origins`     | `["*"]`            | Allowed origins; restrict in production |
| `function_url_auth_type` | `AWS_IAM`          | `AWS_IAM` or `NONE` (master key handles auth) |
| `enable_function_url`    | `true`             | Create a Lambda Function URL; set `false` in regions without function URL support (API Gateway is always created) |
| `config_path`            | `../config.yaml`   | Path to the model list used to derive Bedrock IDs |
| `bedrock_model_ids`      | `[]`               | Extra Bedrock models (beyond `config.yaml`) the IAM role may invoke |

Bedrock model IDs are derived from `config.yaml` (models prefixed `bedrock/`).
The build/destroy scripts read `region`, `name`, `image_tag`,
`lambda_architecture`, and `environment` from `terraform.tfvars` automatically, so
`NAME`/`IMAGE_TAG`/`PLATFORM`/`REGION` don't need to be passed in.

### 2. Store secrets in SSM

Fill in `.env`, then create the SSM parameters (Lambda reads them at runtime):

```bash
set -a && source .env && set +a
aws ssm put-parameter --name "/llm-proxy/$ENVIRONMENT/TOGETHER_API_KEY" --type SecureString --value "$TOGETHER_API_KEY" --overwrite
aws ssm put-parameter --name "/llm-proxy/$ENVIRONMENT/LITELLM_MASTER_KEY" --type SecureString --value "$LITELLM_MASTER_KEY" --overwrite
```

Names default to `/llm-proxy/${environment}/...`; `ENVIRONMENT` is loaded from
`.env` by the `set -a && source .env` step above, so it must match Terraform's
`environment` var.

Alternatively, let Terraform bootstrap the secrets: set `create_secrets = true`
and provide `together_api_key`/`master_key` in `terraform.tfvars` on the first
apply, then set it back to `false`. SSM names can be overridden via
`together_api_key_ssm_name`/`master_key_ssm_name`.

### 3. Build and push the image

> **Fresh environment?** The build script needs the ECR repo to exist, but
> Terraform creates it in step 4. On a fresh deploy (or after a teardown), create
> the repo first, then build:
>
> ```bash
> terraform -chdir=terraform apply -target=aws_ecr_repository.llm_proxy
> ```

```bash
./scripts/build-and-push.sh   # reads region/name/image_tag/arch from terraform.tfvars
```

The image is built for `linux/arm64` (Graviton) — ~20% cheaper Lambda billing.
Override with `PLATFORM=linux/amd64 ./scripts/build-and-push.sh` or set
`lambda_architecture = "x86_64"` in `terraform.tfvars`.

### 4. Apply

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

The `api_gateway_url` output is your OpenAI-compatible endpoint. Load `.env` and
call it with your master key:

```bash
set -a && source .env && set +a
curl -X POST "$(terraform -chdir=terraform output -raw api_gateway_url)/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "deepseek-v4", "messages": [{"role": "user", "content": "Hello"}]}'
```

The `function_url` output is empty unless `enable_function_url = true` (see
[Operational notes](#operational-notes) for regions that don't support it).

> State is stored locally (`terraform/terraform.tfstate`, gitignored). For teams,
> or any real environment, point Terraform at an S3/DynamoDB backend before applying.

### Teardown

```bash
./scripts/destroy.sh
```

Destroy order matters: `destroy.sh` runs `terraform destroy` first (Lambda, API
Gateway, ECR, IAM, CloudWatch, and any SSM params created via `create_secrets =
true`), then deletes the hand-created SSM secrets from step 2, which Terraform
doesn't track. `force_delete = true` on the ECR repo removes the container image
too. Your `.env` (with API keys) is left untouched.

## Operational notes

- **Image tracking:** Terraform tracks the image by ECR digest, so re-running
  `build-and-push.sh` + `terraform apply` picks up new images (no stale `:latest`).
- **Provenance/SBOM:** the build script passes `--provenance=false --sbom=false` —
  without this, AWS Lambda rejects the image media type.
- **Function URL auth:** default is `AWS_IAM`; set `function_url_auth_type = "NONE"`
  in `terraform.tfvars` to make it publicly callable (LiteLLM's master key then
  handles auth).
- **Function URL region support:** Lambda Function URLs aren't available in
  `ap-south-2`, `ap-southeast-4`, `eu-south-2`, `eu-central-2`, `il-central-1`, or
  `me-central-1` — set `enable_function_url = false` there and use the
  `api_gateway_url` endpoint instead.
- **Bedrock model IDs are region-specific:** cross-region inference profiles are
  named per region (`us.`, `apac.`, `au.`, `global.`, ...). A `us.`-prefixed model
  in `config.yaml` won't resolve outside US regions; use the `global.` variant or
  the plain regional model ID for your deploy region.
- **Cold start:** the LiteLLM container takes ~30s to boot, exceeding Lambda's 10s
  init window, so the first request after a cold start returns `503` — retry once
  the container is warm. This also applies after every `terraform apply`.
- **SSO cold start:** the first Bedrock request after SSO login can take minutes
  while credentials initialize.
- **Image layout:** the `dockerfile` builds a multi-arch image — LiteLLM on port
  `8080` behind the AWS Lambda Adapter, exposed via a Lambda function URL and API
  Gateway.
