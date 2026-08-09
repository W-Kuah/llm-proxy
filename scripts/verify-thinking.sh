#!/usr/bin/env bash
# Verify the llm-proxy gateway forwards the thinking mechanic (reasoning_content)
# intact — both non-streaming and streaming. This tests ONLY what the proxy owns:
# that the SSE/JSON path (CloudFront -> Function URL -> Web Adapter -> LiteLLM)
# does not strip or mangle the model's reasoning. It does NOT judge reasoning
# quality (that's model evaluation, out of scope for this repo).
#
# The check is pinned to models known to emit reasoning by DEFAULT with the
# repo's config — it never sends a client-side reasoning_effort switch, because
# litellm_settings.drop_params drops unmodeled params and that path is unreliable.
# If you pass a model not in KNOWN_NATIVE below, the script warns and skips
# instead of failing (so non-thinking routes never false-alarm).
#
# KNOWN_NATIVE map "config.yaml model_name" -> reason it is native:
#   kimi-k2-thinking  -> dedicated Bedrock thinking model (moonshot.kimi-k2-thinking)
#   glm-5             -> Bedrock zai.glm-5 (reasons by default)
#   glm-5.2           -> Together zai-org/GLM-5.2 with reasoning_effort high in config
#   kimi-k2.5         -> Bedrock moonshotai.kimi-k2.5 (extended thinking reporting)
#   deepseek-v4       -> Together DeepSeek-V4-Pro, emits reasoning_content by default
readonly KNOWN_NATIVE=("kimi-k2-thinking" "glm-5" "glm-5.2" "kimi-k2.5" "deepseek-v4-pro")

# Usage: ./scripts/verify-thinking.sh [model]
# Env:   LLM_PROXY_URL (else terraform output), LITELLM_MASTER_KEY (else .env)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

MODEL="${1:-${MODEL:-kimi-k2-thinking}}"
LLM_PROXY_URL="$(resolve_proxy_url "$REPO_ROOT")" || exit 1
LITELLM_MASTER_KEY="$(resolve_master_key "$REPO_ROOT")" || exit 1

if [[ ! " ${KNOWN_NATIVE[*]} " =~ " $MODEL " ]]; then
  echo "SKIP: '$MODEL' is not in KNOWN_NATIVE (${KNOWN_NATIVE[*]})." >&2
  echo "      Thinking-presence is only asserted for models that reason by default." >&2
  exit 0
fi

# A prompt that demands multi-step reasoning so the model reliably produces
# thinking while also answering (some Bedrock thinking routes return empty
# content but non-empty reasoning).
readonly MESSAGES='[{"role":"user","content":"Sally has 3 brothers. Each brother has 2 sisters. How many sisters does Sally have? Explain your reasoning, then give your final answer."}]'

CHECKER="$(mktemp)"
trap 'rm -f "$CHECKER"' EXIT
cat > "$CHECKER" <<'PY'
import json, sys

stream = sys.argv[1] == "true"
raw = sys.stdin.read()

if stream:
    # SSE: at least one data: chunk must carry a non-empty reasoning_content.
    for line in raw.splitlines():
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            continue
        try:
            chunk = json.loads(payload)
        except ValueError:
            continue
        delta = chunk.get("choices", [{}])[0].get("delta", {})
        rc = delta.get("reasoning_content")
        if rc:  # non-empty reasoning delta seen
            sys.exit(0)
    sys.exit(1)

try:
    obj = json.loads(raw)
except ValueError:
    sys.exit(1)

msg = obj.get("choices", [{}])[0].get("message", {})
if msg.get("reasoning_content"):
    sys.exit(0)
sys.exit(1)
PY

check() {
  local stream="$1" payload file
  if [[ "$stream" == "true" ]]; then
    payload="{\"model\":\"$MODEL\",\"messages\":$MESSAGES, \"stream\":true}"
  else
    payload="{\"model\":\"$MODEL\",\"messages\":$MESSAGES}"
  fi

  file="$(mktemp)"
  curl -sS --max-time 180 -X POST "$LLM_PROXY_URL/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" > "$file"

  if python3 "$CHECKER" "$stream" < "$file"; then
    echo "PASS (stream=$stream): model '$MODEL' returned reasoning_content"
  else
    echo "FAIL (stream=$stream): no non-empty reasoning_content in response (see below)" >&2
    sed 's/^/    /' "$file" >&2
    rm -f "$file"
    exit 1
  fi
  rm -f "$file"
}

check "false"
check "true"

echo "OK: '$MODEL' passes thinking through the gateway."
