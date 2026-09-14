#!/usr/bin/env bash
# Verify the admin model-management endpoints (add / disable / enable / delete)
# against a local dynamodb-local + llm-proxy stack. Self-contained: spins up its
# own DynamoDB and proxy, then tears them down.
#
# Usage: ./scripts/verify-admin.sh
# Env:   IMAGE (default llm-proxy:latest), ADMIN_KEY (default test-admin-key),
#        APP_PORT (default 8080)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

IMAGE="${IMAGE:-llm-proxy:latest}"
ADMIN_KEY="${ADMIN_KEY:-test-admin-key}"
TABLE="llm-proxy-models"
NET="llm-admin-test"
APP_PORT="${APP_PORT:-8080}"
MODEL="smoke-test-model"

LITELLM_MASTER_KEY="$(resolve_master_key "$REPO_ROOT")" || exit 1

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Building $IMAGE ..."
  docker build -t "$IMAGE" "$REPO_ROOT"
fi

cleanup() {
  docker rm -f llm-admin-app llm-admin-ddb >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Starting dynamodb-local ..."
docker network create "$NET" >/dev/null
docker run -d --name llm-admin-ddb --network "$NET" amazon/dynamodb-local >/dev/null

echo "Creating table $TABLE ..."
docker run --rm --network "$NET" --entrypoint python \
  -e AWS_REGION=us-east-1 -e AWS_ACCESS_KEY_ID=dummy -e AWS_SECRET_ACCESS_KEY=dummy \
  "$IMAGE" -c "
import boto3
c = boto3.client('dynamodb', region_name='us-east-1', endpoint_url='http://llm-admin-ddb:8000')
c.create_table(TableName='$TABLE', KeySchema=[{'AttributeName':'PK','KeyType':'HASH'},{'AttributeName':'SK','KeyType':'RANGE'}], AttributeDefinitions=[{'AttributeName':'PK','AttributeType':'S'},{'AttributeName':'SK','AttributeType':'S'}], BillingMode='PAY_PER_REQUEST')
print('table created')
"

echo "Starting llm-proxy ..."
docker run -d --name llm-admin-app --network "$NET" -p "$APP_PORT:8080" \
  --env-file "$REPO_ROOT/.env" \
  -e ADMIN_KEY="$ADMIN_KEY" \
  -e MODELS_TABLE="$TABLE" \
  -e AWS_ENDPOINT_URL="http://llm-admin-ddb:8000" \
  -e AWS_REGION=us-east-1 \
  -e AWS_ACCESS_KEY_ID=dummy -e AWS_SECRET_ACCESS_KEY=dummy \
  -e PYTHONUNBUFFERED=1 \
  "$IMAGE" >/dev/null

BASE="http://localhost:$APP_PORT"
ADMIN_AUTH="Authorization: Bearer $ADMIN_KEY"
MASTER_AUTH="Authorization: Bearer $LITELLM_MASTER_KEY"

echo "Waiting for router readiness ..."
ready=""
for _ in $(seq 1 60); do
  if curl -sf -m 2 "$BASE/admin/health" -H "$ADMIN_AUTH" | grep -q '"router_ready":true'; then
    ready=1
    break
  fi
  sleep 2
done
if [[ -z "$ready" ]]; then
  echo "FAIL: proxy did not become ready in time" >&2
  docker logs llm-admin-app >&2
  exit 1
fi

status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $desc (expected HTTP $expected, got $actual)" >&2
    exit 1
  fi
  echo "PASS: $desc"
}

check "health without key -> 401" 401 "$(status -m 5 "$BASE/admin/health")"
check "health with key -> 200" 200 "$(status -m 5 "$BASE/admin/health" -H "$ADMIN_AUTH")"

ADD_BODY='{"model_name":"'"$MODEL"'","litellm_params":{"model":"together_ai/meta-llama/Llama-3.3-70B-Instruct-Turbo","api_key":"os.environ/TOGETHER_API_KEY"}}'
check "add model -> 201" 201 "$(status -m 5 -X POST "$BASE/admin/models" -H "$ADMIN_AUTH" -H 'Content-Type: application/json' -d "$ADD_BODY")"

if ! curl -sf -m 5 "$BASE/v1/models" -H "$MASTER_AUTH" | grep -q "\"id\":\"$MODEL\""; then
  echo "FAIL: added model not visible in /v1/models" >&2
  exit 1
fi
echo "PASS: added model visible in /v1/models"

check "add model missing litellm_params.model -> 400" 400 "$(status -m 5 -X POST "$BASE/admin/models" -H "$ADMIN_AUTH" -H 'Content-Type: application/json' -d '{"model_name":"bad","litellm_params":{}}')"

check "disable model -> 200" 200 "$(status -m 5 -X PATCH "$BASE/admin/models/$MODEL" -H "$ADMIN_AUTH" -H 'Content-Type: application/json' -d '{"enabled":false}')"

if curl -sf -m 5 "$BASE/v1/models" -H "$MASTER_AUTH" | grep -q "\"id\":\"$MODEL\""; then
  echo "FAIL: disabled model still visible in /v1/models" >&2
  exit 1
fi
echo "PASS: disabled model hidden from /v1/models"

check "re-enable model -> 200" 200 "$(status -m 5 -X PATCH "$BASE/admin/models/$MODEL" -H "$ADMIN_AUTH" -H 'Content-Type: application/json' -d '{"enabled":true}')"

if ! curl -sf -m 5 "$BASE/v1/models" -H "$MASTER_AUTH" | grep -q "\"id\":\"$MODEL\""; then
  echo "FAIL: re-enabled model not visible in /v1/models" >&2
  exit 1
fi
echo "PASS: re-enabled model visible in /v1/models"

check "patch non-existent -> 404" 404 "$(status -m 5 -X PATCH "$BASE/admin/models/nope" -H "$ADMIN_AUTH" -H 'Content-Type: application/json' -d '{"enabled":false}')"

check "delete model -> 204" 204 "$(status -m 5 -X DELETE "$BASE/admin/models/$MODEL" -H "$ADMIN_AUTH")"

if curl -sf -m 5 "$BASE/v1/models" -H "$MASTER_AUTH" | grep -q "\"id\":\"$MODEL\""; then
  echo "FAIL: deleted model still visible in /v1/models" >&2
  exit 1
fi
echo "PASS: deleted model hidden from /v1/models"

check "delete non-existent -> 404" 404 "$(status -m 5 -X DELETE "$BASE/admin/models/nope" -H "$ADMIN_AUTH")"

PROVIDER_BODY='{"provider":"together_ai","credentialRef":"/llm-proxy/dev/TOGETHER_API_KEY"}'
check "register provider -> 201" 201 "$(status -m 5 -X POST "$BASE/admin/providers" -H "$ADMIN_AUTH" -H 'Content-Type: application/json' -d "$PROVIDER_BODY")"

if ! curl -sf -m 5 "$BASE/admin/providers" -H "$ADMIN_AUTH" | grep -q '"provider":"together_ai"'; then
  echo "FAIL: registered provider not visible in /admin/providers" >&2
  exit 1
fi
echo "PASS: registered provider visible in /admin/providers"

check "register provider missing credentialRef -> 400" 400 "$(status -m 5 -X POST "$BASE/admin/providers" -H "$ADMIN_AUTH" -H 'Content-Type: application/json' -d '{"provider":"openai"}')"

echo "OK: admin model-management endpoints work end-to-end."
