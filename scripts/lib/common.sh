#!/usr/bin/env bash
# Shared helpers sourced by llm-proxy scripts.

# Read a simple `key = "value"` from terraform.tfvars (single source of truth),
# falling back to a default. Env vars passed in still take precedence.
tfvar() {
  local tfvars="$1" key="$2" default="$3" val=""
  if [[ -f "$tfvars" ]]; then
    val="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$tfvars" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*$/\1/')"
  fi
  printf '%s' "${val:-$default}"
}

# Resolve gateway URL: env LLM_PROXY_URL > terraform output > error.
resolve_proxy_url() {
  local repo_root="$1" url="${LLM_PROXY_URL:-}"
  if [[ -n "$url" ]]; then
    echo "$url"
    return 0
  fi
  url="$(terraform -chdir="$repo_root/terraform" output -raw cloudfront_url 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    echo "$url"
    return 0
  fi
  echo "ERROR: set LLM_PROXY_URL (or run terraform apply first)" >&2
  return 1
}

# Resolve master key: env LITELLM_MASTER_KEY > .env > error.
resolve_master_key() {
  local repo_root="$1" key="${LITELLM_MASTER_KEY:-}"
  if [[ -n "$key" ]]; then
    echo "$key"
    return 0
  fi
  if [[ -f "$repo_root/.env" ]]; then
    set -a; source "$repo_root/.env"; set +a
    key="${LITELLM_MASTER_KEY:-}"
  fi
  if [[ -n "$key" ]]; then
    echo "$key"
    return 0
  fi
  echo "ERROR: LITELLM_MASTER_KEY not set (and no .env found)" >&2
  return 1
}
