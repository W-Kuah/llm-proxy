#!/usr/bin/env bash
# Verify the llm-proxy gateway returns real tool calls for a model — both
# non-streaming and streaming. Run this BEFORE debugging opencode tool calls so
# you know whether the issue is the proxy or the client.
#
# Usage: ./scripts/verify-tools.sh [model]
# Env:   LLM_PROXY_URL (else terraform output), LITELLM_MASTER_KEY (else .env)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

MODEL="${1:-${MODEL:-deepseek-v4}}"
LLM_PROXY_URL="$(resolve_proxy_url "$REPO_ROOT")" || exit 1
LITELLM_MASTER_KEY="$(resolve_master_key "$REPO_ROOT")" || exit 1

readonly TOOLS='[{"type":"function","function":{"name":"get_weather","description":"Get the current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]'
readonly MESSAGES='[{"role":"user","content":"What is the weather in San Francisco? Use the get_weather tool."}]'

CHECKER="$(mktemp)"
trap 'rm -f "$CHECKER"' EXIT
cat > "$CHECKER" <<'PY'
import json, sys

mode, stream = sys.argv[1], sys.argv[2] == "true"
raw = sys.stdin.read()

if stream:
    # SSE: tool calls surface as "tool_calls" in a data: chunk.
    sys.exit(0 if "tool_calls" in raw else 1)

try:
    obj = json.loads(raw)
except ValueError:
    sys.exit(1)

for tc in obj.get("choices", [{}])[0].get("message", {}).get("tool_calls", []):
    fn = tc.get("function", {})
    if fn.get("name") != "get_weather":
        continue
    try:
        args = json.loads(fn.get("arguments", ""))
    except (TypeError, ValueError):
        continue
    if args.get("city"):
        sys.exit(0)
sys.exit(1)
PY

check() {
  local mode="$1" stream="$2" payload file
  if [[ "$stream" == "true" ]]; then
    payload="{\"model\":\"$MODEL\",\"messages\":$MESSAGES,\"tools\":$TOOLS,\"tool_choice\":\"auto\",\"stream\":true}"
  else
    payload="{\"model\":\"$MODEL\",\"messages\":$MESSAGES,\"tools\":$TOOLS,\"tool_choice\":\"auto\"}"
  fi

  file="$(mktemp)"
  curl -sS --max-time 180 -X POST "$LLM_PROXY_URL/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" > "$file"

  if python3 "$CHECKER" "$mode" "$stream" < "$file"; then
    echo "PASS ($mode): model '$MODEL' returned a valid tool call"
  else
    echo "FAIL ($mode): no valid tool call in response (see below)" >&2
    if grep -q 'reasoning_content' "$file"; then
      echo "HINT: model ran in thinking mode (reasoning_content present) with no tool call." >&2
      echo "      Likely 'tools' was dropped for this route (drop_params: true) or thinking interferes." >&2
      echo "      Try a non-thinking model: ./scripts/verify-tools.sh claude-sonnet" >&2
    fi
    sed 's/^/    /' "$file" >&2
    rm -f "$file"
    exit 1
  fi
  rm -f "$file"
}

check "non-streaming" "false"
check "streaming" "true"

echo "OK: '$MODEL' does tool calls through the gateway."
