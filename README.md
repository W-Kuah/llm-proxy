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
- [Tests](#tests)

## Overview

- Routes requests to Claude, Kimi, GLM (Amazon Bedrock) and Llama 3.3, Kimi, DeepSeek, GLM (Together AI)
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

### Model routing (`config.yaml` — seed + local-dev fallback)

The runtime catalog lives in DynamoDB; `config.yaml` seeds it and serves as the
fallback when `MODELS_TABLE` is unset (local `docker run`). The seeded models:| Model name         | Provider       | Backend model                                                                                              |
| ------------------ | -------------- | ---------------------------------------------------------------------------------------------------------- |
| `claude-sonnet`    | Amazon Bedrock | `global.anthropic.claude-sonnet-4-5-20250929-v1:0` (cross-region `global.` inference profile)              |
| `kimi-k2.5`        | Amazon Bedrock | `moonshotai.kimi-k2.5`                                                                                     |
| `kimi-k2-thinking` | Amazon Bedrock | `moonshot.kimi-k2-thinking`                                                                                |
| `glm-5`            | Amazon Bedrock | `zai.glm-5`                                                                                                |
| `llama3.3-70b`     | Together AI    | `meta-llama/Llama-3.3-70B-Instruct-Turbo`                                                                  |
| `kimi-k3`          | Together AI    | `moonshotai/Kimi-K3`                                                                                       |
| `deepseek-v4`      | Together AI    | `deepseek-ai/DeepSeek-V4-Pro`                                                                              |
| `glm-5.2`          | Together AI    | `zai-org/GLM-5.2`                                                                                          |

The **provider prefix** in `litellm_params.model` (before the first `/`) tells
LiteLLM how to route:

| Provider            | Prefix        | IAM change?                       | API key                    |
| ------------------- | ------------- | --------------------------------- | -------------------------- |
| Amazon Bedrock      | `bedrock/`    | No — role is wildcarded           | none (Lambda's IAM role)   |
| Together AI         | `together_ai/`| No                                | `TOGETHER_API_KEY` (shared)|
| Any other provider  | e.g. `openai/`| No                                | needs its own env key      |

### Adding a model

Models are **runtime-managed in DynamoDB** — `config.yaml` is only a seed and a
local-dev fallback, not the source of truth. Add a model via the admin API
(no redeploy):

```bash
curl -X POST "$(terraform -chdir=terraform output -raw cloudfront_url)/admin/models" \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model_name": "my-claude",
    "litellm_params": {
      "model": "bedrock/global.anthropic.claude-sonnet-...-v1:0"
    }
  }'
```

**Bedrock** needs no key — the Lambda's IAM role authenticates, and the role is
wildcarded (`foundation-model/*`, `inference-profile/*`) so new Bedrock models
work with zero IAM changes.

**Together AI** uses the shared `TOGETHER_API_KEY` (already wired SSM → Lambda
env) via `"api_key": "os.environ/TOGETHER_API_KEY"`.

**Any other provider** needs its own key, wired in three places:

1. SSM Parameter Store: store the key (same `/llm-proxy/<env>/...` pattern).
2. `app.py`: add a `*_SSM_NAME` → env-var entry to `_SSM_SECRET_ENV_MAP`, and
   `terraform/lambda.tf`: pass the SSM name into the Lambda `environment`.
3. Reference it in the model's `litellm_params` as `"api_key": "os.environ/<KEY>"`, then `terraform apply`.

The Lambda resolves each `*_SSM_NAME` env var into its value at cold start via
`ssm:GetParameter` (see `_load_secrets_from_ssm`), so there's no deploy-time
dependency on the params existing.

The new model is immediately available at `/v1/chat/completions`; check
`/v1/models`. To seed the catalog from `config.yaml` (one-off migration), run
`scripts/seed-models.py` after the table exists.

### Environment variables

| Variable             | Purpose                                        |
| -------------------- | ---------------------------------------------- |
| `TOGETHER_API_KEY`   | API key for Together AI                        |
| `LITELLM_MASTER_KEY` | Master key for LiteLLM (`general_settings`)    |
| `ADMIN_KEY`          | Bearer key for the `/admin/*` routes           |
| `MODELS_TABLE`       | DynamoDB table name for the runtime catalog    |
| `AWS_REGION`         | Region for Bedrock (uses credentials from IAM) |
| `ENVIRONMENT`        | Optional. Basename for SSM secret paths (`/llm-proxy/<env>/...`); must match Terraform's `environment` var |

In Lambda, the three keys are resolved at cold start from SSM instead of being
baked in: the function receives `TOGETHER_API_KEY_SSM_NAME`,
`MASTER_KEY_SSM_NAME`, and `ADMIN_KEY_SSM_NAME` (the parameter *names*), and
`app.py` reads their values via `ssm:GetParameter`. Locally you pass the values
directly (`.env`).

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

> Verified: both `llama3.3-70b` (Together) and `claude-sonnet` (Bedrock) return completions this way.

### pip (no Docker)

```bash
pip install "litellm[proxy]"
set -a && source .env && set +a
python app.py   # falls back to config.yaml when MODELS_TABLE is unset
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
| IAM role + policies           | Lambda execution, Bedrock invoke (wildcard), DynamoDB, SSM read, ECR pull |
| DynamoDB `Models` table       | Runtime model catalog + provider credential refs |
| CloudFront distribution        | Public HTTPS front-door, OAC → Lambda Function URL |
| Lambda function               | Container image, arm64, 2048 MB, 300 s timeout (configurable) |
| Lambda function URL           | Origin for CloudFront, `RESPONSE_STREAM` invoke mode (SSE streaming) |
| CloudWatch log group          | Logs, 1-day retention (configurable)                    |
| SSM Parameter Store (optional)| SecureString keys for `TOGETHER_API_KEY`, `LITELLM_MASTER_KEY`, `ADMIN_KEY` |

### Prerequisites

- Terraform >= 1.5
- AWS credentials with permissions for ECR, Lambda, IAM, SSM, CloudWatch, CloudFront
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
| `region`                 | `us-east-1`        | AWS region for all resources + Lambda's `AWS_REGION` (must support Lambda Function URLs) |
| `environment`            | `dev`              | Baked into SSM secret paths (`/llm-proxy/<env>/...`) |
| `name`                   | `llm-proxy`        | Base name for Lambda/ECR/IAM/CloudFront resources |
| `image_tag`              | `latest`           | ECR tag to deploy; read by `build-and-push.sh` |
| `lambda_memory_size`     | `2048`             | Lambda memory in MB                     |
| `lambda_timeout`         | `300`              | Lambda timeout in seconds               |
| `lambda_architecture`    | `arm64`            | `arm64` or `x86_64`                     |
| `log_retention_days`     | `1`                | CloudWatch retention                    |
| `cors_allow_origins`     | `["*"]`            | Allowed origins; restrict in production |
| `function_url_auth_type` | `NONE`             | Auth is the LiteLLM master key at the app layer; `NONE` is required so CloudFront (OAC `no-override`) can forward the viewer's Bearer token |
| `cloudfront_price_class` | `PriceClass_All`   | CloudFront edge coverage vs cost        |

The model catalog is runtime-managed in DynamoDB, so Bedrock IAM is wildcarded
(`foundation-model/*`, `inference-profile/*`) and `config.yaml` is a seed only —
no `config_path`/`bedrock_model_ids` variables exist anymore. The build/destroy
scripts read `region`, `name`, `image_tag`, `lambda_architecture`, and
`environment` from `terraform.tfvars` automatically, so
`NAME`/`IMAGE_TAG`/`PLATFORM`/`REGION` don't need to be passed in.

### 2. Store secrets in SSM

Fill in `.env`, then create the SSM parameters (Lambda reads them at runtime):

```bash
set -a && source .env && set +a
aws ssm put-parameter --name "/llm-proxy/$ENVIRONMENT/TOGETHER_API_KEY" --type SecureString --value "$TOGETHER_API_KEY" --overwrite
aws ssm put-parameter --name "/llm-proxy/$ENVIRONMENT/LITELLM_MASTER_KEY" --type SecureString --value "$LITELLM_MASTER_KEY" --overwrite
aws ssm put-parameter --name "/llm-proxy/$ENVIRONMENT/ADMIN_KEY" --type SecureString --value "$ADMIN_KEY" --overwrite
```

Names default to `/llm-proxy/${environment}/...`; `ENVIRONMENT` is loaded from
`.env` by the `set -a && source .env` step above, so it must match Terraform's
`environment` var.

Alternatively, let Terraform bootstrap the secrets: set `create_secrets = true`
and provide `together_api_key`/`master_key`/`admin_key` in `terraform.tfvars` on
the first apply, then set it back to `false`. SSM names can be overridden via
`together_api_key_ssm_name`/`master_key_ssm_name`/`admin_key_ssm_name`.

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

The `cloudfront_url` output is your OpenAI-compatible endpoint. Load `.env` and
call it with your master key:

### 5. Seed the model catalog (one-time)

After the first `terraform apply` creates the DynamoDB table, seed it from
`config.yaml`:

```bash
MODELS_TABLE=llm-proxy-models AWS_REGION=ap-southeast-2 uv run --with boto3 --with PyYAML python3 scripts/seed-models.py
```

This writes the 8 models from `config.yaml` into the runtime catalog. Subsequent
deploys don't need this — the table persists.

```bash
set -a && source .env && set +a
curl -X GET "$(terraform -chdir=terraform output -raw cloudfront_url)/v1/models" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json"
```

```bash
set -a && source .env && set +a
curl -X POST "$(terraform -chdir=terraform output -raw cloudfront_url)/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "deepseek-v4-pro", "messages": [{"role": "user", "content": "Hello"}]}'
```

Streaming (SSE) works the same — pass `"stream": true` and you'll get
`data:` chunks as they arrive; the Function URL runs in `RESPONSE_STREAM`
invoke mode with the Web Adapter set to `AWS_LWA_INVOKE_MODE=response_stream`.

> The `function_url` output is the underlying origin — not for direct client use.
> CloudFront (`cloudfront_url`) is the public endpoint.

> State is stored locally (`terraform/terraform.tfstate`, gitignored). For teams,
> or any real environment, point Terraform at an S3/DynamoDB backend before applying.

### Teardown

```bash
./scripts/destroy.sh
```

Destroy order matters: `destroy.sh` runs `terraform destroy` first (Lambda,
CloudFront, ECR, IAM, CloudWatch, and any SSM params created via `create_secrets =
true`), then deletes the hand-created SSM secrets from step 2
(`TOGETHER_API_KEY`, `LITELLM_MASTER_KEY`, `ADMIN_KEY`), which Terraform doesn't
track. `force_delete = true` on the ECR repo removes the container image too.
Your `.env` (with API keys) is left untouched.

## Operational notes

- **Image tracking:** Terraform tracks the image by ECR digest, so re-running
  `build-and-push.sh` + `terraform apply` picks up new images (no stale `:latest`).
- **Provenance/SBOM:** the build script passes `--provenance=false --sbom=false` —
  without this, AWS Lambda rejects the image media type.
- **Function URL auth:** `function_url_auth_type` must stay `"NONE"`, and the
  CloudFront OAC signing behavior must stay `no-override` (not `always`). With
  `always`, CloudFront overwrites the viewer's `Authorization` header with its own
  SigV4 signature and LiteLLM never sees the Bearer key. With `NONE` + `no-override`,
  CloudFront forwards the viewer Bearer token straight through; the LiteLLM master
  key is the only auth boundary (best-effort — the Function URL is publicly
  callable). Do NOT add `aws_lambda_permission` grants scoped to
  `cloudfront.amazonaws.com`: auth `NONE` requires a public `*` grant
  (`lambda:InvokeFunctionUrl` + `lambda:InvokeFunction`), and the CloudFront-only
  grants aren't matched on unsigned `no-override` origin calls → 403.
- **Region support:** Lambda Function URLs aren't available in `ap-south-2`,
  `ap-southeast-4`, `eu-south-2`, `eu-central-2`, `il-central-1`, or
  `me-central-1` — the stack must deploy in a supported region (this repo uses
  `ap-southeast-2`).
- **Bedrock model IDs are region-specific:** cross-region inference profiles are
  named per region (`us.`, `apac.`, `au.`, `global.`, ...). A `us.`-prefixed model
  in `config.yaml` won't resolve outside US regions; use the `global.` variant or
  the plain regional model ID for your deploy region.
- **Cold start:** the LiteLLM container takes ~30s to boot, exceeding Lambda's 10s
  init window. `AWS_LWA_ASYNC_INIT=true` (set in `terraform/lambda.tf`) makes the
  AWS Lambda Adapter wait for the app to finish booting instead of returning `503`
  at the 10s init wall, so the first request after a cold start (and the first
  request after every `terraform apply`) blocks until LiteLLM is ready rather than
  `503`ing — it will just take noticeably longer than a warm request.
- **SSO cold start:** the first Bedrock request after SSO login can take minutes
  while credentials initialize.
- **Image layout:** the `Dockerfile` builds a multi-arch image — LiteLLM on port
  `8080` behind the AWS Lambda Adapter in `response_stream` mode, exposed via the
  Function URL with CloudFront in front.
- **Custom domain:** no domain is wired yet — CloudFront serves from a
  `*.cloudfront.net` URL. To add one later: import the domain as a Route 53 hosted
  zone, request an ACM cert (us-east-1), set `aliases` + `viewer_certificate` on
  the distribution, and add an A/AAAA alias record.

## Tests

### Unit tests

`tests/test_app.py` covers the admin model-management endpoints (add / disable /
enable / delete) and the secret-resolution logic, using `moto` to mock DynamoDB
and an injectable `get_secret` to avoid real SSM calls. Deps are in
`requirements-dev.txt` (`pytest`, `moto`, `PyYAML`).

```bash
# one-off, no venv needed (uv fetches the deps):
uv run --with pytest --with moto --with PyYAML python -m pytest tests/ -q

# or with a venv:
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest tests/ -q
```

### Admin endpoint smoke test

`scripts/verify-admin.sh` spins up its own `dynamodb-local` + proxy stack and
exercises the admin endpoints end-to-end (auth, add, disable, enable, delete,
and the 400/404 cases), then tears everything down.

```bash
./scripts/verify-admin.sh
# Env: IMAGE (default llm-proxy:latest), ADMIN_KEY (default test-admin-key),
#      APP_PORT (default 8080)
```

## Smoke checks

Two scripts verify the proxy passes through tool calls and thinking
intact — useful after a deploy or config change. Both need the gateway URL and
master key (pull from `terraform output` + `.env` automatically, or set
`LLM_PROXY_URL` / `LITELLM_MASTER_KEY`).

```bash
./scripts/verify-tools.sh [model]      # default: deepseek-v4
./scripts/verify-thinking.sh [model]   # default: kimi-k2-thinking
```

Each runs both non-streaming and streaming and reports PASS/FAIL.
