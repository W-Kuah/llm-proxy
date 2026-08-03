# llm-proxy

A thin LLM API gateway built on [LiteLLM](https://github.com/BerriAI/litellm) that exposes multiple model providers behind a single OpenAI-compatible endpoint, deployed as an AWS Lambda container.

## What it does

- Routes requests to Claude (via Amazon Bedrock) and Llama 3 (via Together AI)
- Provides one consistent OpenAI-compatible API surface
- Runs as a serverless container on AWS Lambda (via the AWS Lambda Adapter)

## Configuration

Model routing is defined in `config.yaml`:

| Model name       | Provider          | Backend model                                                        |
| ---------------- | ----------------- | -------------------------------------------------------------------- |
| `claude-sonnet`  | Amazon Bedrock    | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` (us-east-1)          |
| `llama3-8bq`     | Together AI       | `meta-llama/Llama-3.3-70B-Instruct-Turbo`                           |

### Adding a model

To expose a new model, update **two places** so routing and IAM stay in sync:

1. **`config.yaml`** — add an entry to `model_list`:
   ```yaml
   - model_name: my-model
     litellm_params:
       model: <provider>/<backend-model>        # e.g. together_ai/meta-llama/...
       api_key: os.environ/MY_PROVIDER_KEY     # if the provider needs a key
   ```
   For a Bedrock route, set `aws_region_name` explicitly if it differs from
   `AWS_REGION`. If the provider needs an API key, it must be present in the
   runtime env (`.env` locally, Lambda `environment` in `lambda.tf`, and SSM).

2. **`terraform.tfvars`** — if the model is on Bedrock, append its ID to
   `bedrock_model_ids` so the Lambda IAM role can invoke it:
   ```hcl
   bedrock_model_ids = [
     "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
     "anthropic.claude-new-model",
   ]
   ```
   Non-Bedrock providers (e.g. Together) need no IAM change.

3. If the provider uses an API key, add `MY_PROVIDER_KEY` to your SSM
   Parameter Store and to the Lambda `environment` in `lambda.tf`.

Then rebuild + redeploy (`./scripts/build-and-push.sh`, `terraform apply`), or just
restart the local container for a local-only test. The new model is immediately
available at `/v1/chat/completions`; check `/v1/models`.

### Required environment variables:

| Variable            | Purpose                                       |
| ------------------- | --------------------------------------------- |
| `TOGETHER_API_KEY`  | API key for Together AI                       |
| `LITELLM_MASTER_KEY`| Master key for LiteLLM (`general_settings`)    |
| `AWS_REGION`        | Region for Bedrock (uses credentials from IAM)|

Create a `.env` file with your keys (it's gitignored, so safe to keep locally):

```bash
TOGETHER_API_KEY=tgp_v1_xxxxxxxxxxxxxxxxxxxx
LITELLM_MASTER_KEY=sk-your-master-key
AWS_REGION=us-east-1
```

`TOGETHER_API_KEY`, `LITELLM_MASTER_KEY`, and `AWS_REGION` are read from the
environment at runtime. `ENVIRONMENT` (e.g. `dev`) is optional and is used as the
default basename for the SSM secret paths when uploading them — set it so both the
README's `ssm put-parameter` step and Terraform's `environment` var point to the
same secrets.

## Usage

There are two ways to run the proxy locally: via Docker (no Python install needed)
or via pip.

### Option A (recommended): Docker

Build the image (same `dockerfile` used for Lambda) and run it, loading keys from
`.env` and your config:

```bash
docker build -t llm-proxy .
docker run --rm -p 8080:8080 \
  --env-file .env \
  -e AWS_PROFILE=default   # set to your AWS profile name (required for SSO-based creds)
  -v ~/.aws:/root/.aws:ro \
  llm-proxy
```

- `--env-file .env` loads `TOGETHER_API_KEY`, `LITELLM_MASTER_KEY`, `AWS_REGION`.
- `-v ~/.aws:/root/.aws:ro` mounts your AWS credentials so the `claude-sonnet`
  route (Bedrock) can authenticate.
- With **SSO** credentials the container can't auto-pick a profile, so set
  `AWS_PROFILE` to the profile name in `~/.aws/config` (e.g. `defaultAdmin`).
  Note the first request can be slow (minutes) while SSO creds initialize.

> Verified: both `llama3-8bq` (Together) and `claude-sonnet` (Bedrock) return
> completions when run this way.

### Option B: pip (no Docker)

You'll need [LiteLLM](https://github.com/BerriAI/litellm) installed and the runtime
variables loaded:

```bash
pip install "litellm[proxy]"
set -a && source .env && set +a   # loads TOGETHER_API_KEY, LITELLM_MASTER_KEY, AWS_REGION
```

Start the proxy locally:

```bash
litellm --config config.yaml --port 8080
```

Call a model:

> Locally, the `claude-sonnet` route calls Bedrock, so it needs valid AWS
> credentials in your shell; `llama3-8bq` uses the `TOGETHER_API_KEY` from `.env`.

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

## Deployment (IaC)

The infrastructure is defined as code with Terraform in `terraform/`:

| Resource                      | Description                                    |
| ----------------------------- | ---------------------------------------------- |
| ECR repository                | Stores the `llm-proxy` container image         |
| IAM role + policies           | Lambda execution, Bedrock invoke, ECR pull     |
| Lambda function               | Container image, arm64, 2048 MB, 300 s timeout (all configurable) |
| Lambda function URL           | Public HTTPS endpoint                          |
| CloudWatch log group          | Logs, 14-day retention (configurable)              |
| SSM Parameter Store (optional)| SecureString keys for `TOGETHER_API_KEY` and `LITELLM_MASTER_KEY` |

### Prerequisites

- Terraform >= 1.5
- AWS credentials with permissions for ECR, Lambda, IAM, SSM, and CloudWatch
- Docker (for the build script)
- For local runs only: Docker **or** Python 3.9+ with `pip install "litellm[proxy]"`
- The AWS CLI with a configured profile (see below)

#### AWS access (SSO)

Commands (AWS CLI, Terraform, and the Bedrock route) authenticate via your AWS
credentials. With SSO, log in once and point tooling at your profile:

```bash
aws sso login --sso-session default     # or: aws configure sso to create one
export AWS_PROFILE=defaultAdmin         # the profile name in ~/.aws/config
```

For the **local Docker run** the profile must also be passed into the container
(`-e AWS_PROFILE=<profile>`); it can't auto-pick one. Terraform and the AWS CLI
use whatever profile is exported in your shell.

### 0a. Configure environment

In addition to `.env`, the deployment is customized via `terraform.tfvars`
(it's gitignored). Start from the example and set `environment`, `name`, and any
tuning you want:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Key options (see the example for the full list):

| Variable              | Default                 | Meaning                                  |
| --------------------- | ----------------------- | ---------------------------------------- |
| `environment`         | `dev`                   | Baked into SSM secret paths (`/llm-proxy/<env>/...`) |
| `name`                | `llm-proxy`             | Base name for Lambda/ECR/IAM/API GW resources |
| `lambda_memory_size`  | `2048`                  | Lambda memory in MB                     |
| `lambda_timeout`      | `300`                   | Lambda timeout in seconds               |
| `log_retention_days`  | `14`                    | CloudWatch retention                    |
| `lambda_architecture` | `arm64`                 | `arm64` or `x86_64`                     |
| `cors_allow_origins`  | `["*"]`                 | Allowed origins; restrict in production |
| `bedrock_model_ids`   | `["us.anthropic..."]`   | Bedrock models the IAM role may invoke; must match `config.yaml` |

`bedrock_model_ids` must stay in sync with the models defined in `config.yaml`,
and `NAME`/`IMAGE_TAG` passed to the build script should match `name`/`image_tag`
above.

### 1. Store secrets in SSM

Fill in `.env` with your keys, then create the SSM parameters (Lambda reads them at runtime):

```bash
set -a && source .env && set +a
aws ssm put-parameter --name "/llm-proxy/$ENVIRONMENT/TOGETHER_API_KEY" --type SecureString --value "$TOGETHER_API_KEY" --overwrite
aws ssm put-parameter --name "/llm-proxy/$ENVIRONMENT/LITELLM_MASTER_KEY" --type SecureString --value "$LITELLM_MASTER_KEY" --overwrite
```

The SSM parameter names default to `/llm-proxy/${environment}/...`, so set
`ENVIRONMENT=dev` (or match Terraform's `environment` var) in your shell before
running the command above.

### 2. Build and push the image

```bash
./scripts/build-and-push.sh   # defaults: us-east-1, llm-proxy:latest, linux/arm64
```

The image is built for `linux/arm64` (Graviton) — ~20% cheaper Lambda billing. Override with `PLATFORM=linux/amd64 ./scripts/build-and-push.sh` if needed.

### 3. Apply the infrastructure

```bash
cd terraform
terraform init
terraform apply
```

The `function_url` output is your OpenAI-compatible endpoint. Call it with `Authorization: Bearer <LITELLM_MASTER_KEY>`:

```bash
curl -X POST "$(terraform output -raw function_url)/v1/chat/completions" \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-sonnet", "messages": [{"role": "user", "content": "Hello"}]}'
```

### Teardown

To tear down the infrastructure (for example, to save cost in a dev environment):

```bash
./scripts/destroy.sh
```

This removes any hand-created SSM secrets from the README's parameter-store step
(Terraform doesn't track those), then runs `terraform destroy` on everything it
manages (Lambda, API Gateway, ECR, IAM, CloudWatch, and any SSM params created via
`create_secrets = true`). `force_delete = true` on the ECR repo means the container
image is deleted too. Your `.env` (with API keys) is left untouched.

### Notes

- **State is stored locally** (`terraform/terraform.tfstate`, gitignored). For teams, or any real environment, point Terraform at an S3/DynamoDB backend before running `apply`.
- Alternatively to the manual `aws ssm put-parameter` step above, you can let Terraform bootstrap the secrets by setting `create_secrets = true` and providing `together_api_key`/`master_key` in `terraform.tfvars` on the first apply. Keep `create_secrets = true` only for the initial deploy.

- `config.yaml` routes Claude through Bedrock; the Lambda role is scoped to that one model ARN (across regions, for cross-region inference profiles).
- The Terraform config tracks the image by ECR digest, so re-running `build-and-push.sh` + `terraform apply` picks up new images automatically (no stale `:latest`).
- The build script disables BuildKit provenance/SBOM attestations (`--provenance=false --sbom=false`) — without this, AWS Lambda rejects the image media type.
- Default function URL auth is `AWS_IAM`; set `function_url_auth_type = "NONE"` in a `terraform.tfvars` to make it publicly callable (LiteLLM's master key then handles auth).
- The `dockerfile` builds a multi-arch image: LiteLLM on port `8080` behind the AWS Lambda Adapter, exposed via a Lambda function URL.
