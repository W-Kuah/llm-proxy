#!/usr/bin/env python3
"""Custom LiteLLM proxy entrypoint.

Replaces the stock `litellm` CLI so the model catalog can be sourced from
DynamoDB at cold start (with config.yaml as a local-dev fallback) and mutated
live via the admin routes.

Flow:
  1. Read static settings (general_settings / litellm_settings) from config.yaml.
  2. If MODELS_TABLE is set, read the model catalog from DynamoDB; otherwise
     fall back to config.yaml's model_list.
  3. Write the merged config to /tmp/config.yaml and point CONFIG_FILE_PATH at
     it so LiteLLM's proxy_startup_event loads it.
  4. Import the LiteLLM proxy app, register admin routes, and run uvicorn.
"""

import json
import os
import time

import yaml

STATIC_CONFIG_PATH = "/app/config.yaml"
RUNTIME_CONFIG_PATH = "/tmp/config.yaml"
PORT = int(os.environ.get("PORT", "8080"))
CATALOG_TTL = 60.0

_catalog_cache: dict = {"data": None, "fetched_at": 0.0}


def _read_static_config() -> dict:
    with open(STATIC_CONFIG_PATH) as f:
        return yaml.safe_load(f) or {}


def _dynamodb_client():
    import boto3

    kwargs = {}
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    if region:
        kwargs["region_name"] = region
    endpoint = os.environ.get("AWS_ENDPOINT_URL")
    if endpoint:
        kwargs["endpoint_url"] = endpoint
    return boto3.client("dynamodb", **kwargs)


# Map of env var holding an SSM parameter *name* -> env var to populate with the
# resolved value. Populated at cold start so the Lambda no longer depends on
# deploy-time data sources (which made `terraform destroy` fail when a param was
# missing). Local runs pass the values directly and leave these unset.
_SSM_SECRET_ENV_MAP = {
    "TOGETHER_API_KEY_SSM_NAME": "TOGETHER_API_KEY",
    "MASTER_KEY_SSM_NAME": "LITELLM_MASTER_KEY",
    "ADMIN_KEY_SSM_NAME": "ADMIN_KEY",
}


def _load_secrets_from_ssm() -> None:
    import boto3

    names = {k: os.environ.get(k) for k in _SSM_SECRET_ENV_MAP}
    if not any(names.values()):
        return
    kwargs = {}
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    if region:
        kwargs["region_name"] = region
    ssm = boto3.client("ssm", **kwargs)
    for name_env, value_env in _SSM_SECRET_ENV_MAP.items():
        name = names[name_env]
        if not name:
            continue
        try:
            resp = ssm.get_parameter(Name=name, WithDecryption=True)
            os.environ[value_env] = resp["Parameter"]["Value"]
        except Exception:
            # Leave unset; LiteLLM surfaces the error later if the key is needed.
            pass


def _read_catalog_from_dynamodb(table: str) -> list[dict]:
    ddb = _dynamodb_client()
    catalog: list[dict] = []
    paginator = ddb.get_paginator("query")
    for page in paginator.paginate(
        TableName=table,
        KeyConditionExpression="PK = :pk",
        ExpressionAttributeValues={":pk": {"S": "CATALOG"}},
    ):
        for item in page.get("Items", []):
            entry = {
                "model_name": item.get("model_name", {}).get("S", ""),
                "provider": item.get("provider", {}).get("S", ""),
                "enabled": item.get("enabled", {}).get("BOOL", True),
                "litellm_params": json.loads(
                    item.get("litellm_params", {}).get("S", "{}")
                ),
            }
            if "credentialRef" in item:
                entry["credentialRef"] = item["credentialRef"].get("S")
            if "pricing" in item:
                entry["pricing"] = json.loads(item["pricing"].get("S", "{}"))
            catalog.append(entry)
    return catalog


def _get_catalog(force: bool = False) -> list[dict] | None:
    table = os.environ.get("MODELS_TABLE")
    if not table:
        return None
    now = time.time()
    if (
        not force
        and _catalog_cache["data"] is not None
        and (now - _catalog_cache["fetched_at"]) < CATALOG_TTL
    ):
        return _catalog_cache["data"]
    data = _read_catalog_from_dynamodb(table)
    _catalog_cache["data"] = data
    _catalog_cache["fetched_at"] = now
    return data


def _invalidate_cache() -> None:
    _catalog_cache["data"] = None
    _catalog_cache["fetched_at"] = 0.0


def _build_model_list(catalog: list[dict]) -> list[dict]:
    return [
        {"model_name": e["model_name"], "litellm_params": e["litellm_params"]}
        for e in catalog
        if e["enabled"]
    ]


def build_config() -> dict:
    static = _read_static_config()
    catalog = _get_catalog()
    if catalog is not None:
        model_list = _build_model_list(catalog)
    else:
        model_list = static.get("model_list", [])
    config = dict(static)
    config["model_list"] = model_list
    return config


def _resolve_litellm_params(litellm_params: dict, get_secret=None) -> dict:
    if get_secret is None:
        from litellm.secret_managers.main import get_secret

    resolved: dict = {}
    for k, v in litellm_params.items():
        if isinstance(v, str) and v.startswith("os.environ/"):
            resolved[k] = get_secret(v)
        else:
            resolved[k] = v
    return resolved


def _to_deployment(model_name: str, litellm_params: dict):
    from litellm.router import Deployment, LiteLLM_Params

    resolved = _resolve_litellm_params(litellm_params)
    return Deployment(
        model_name=model_name,
        litellm_params=LiteLLM_Params(**resolved),
    )


def _upsert_router(proxy_server, model_name: str, litellm_params: dict) -> None:
    router = proxy_server.llm_router
    if router is None:
        return
    router.upsert_deployment(deployment=_to_deployment(model_name, litellm_params))


def _delete_router(proxy_server, model_name: str) -> None:
    router = proxy_server.llm_router
    if router is None:
        return
    for model_id in router.get_model_ids():
        deployment = router.get_deployment(model_id=model_id)
        if deployment is not None and getattr(deployment, "model_name", None) == model_name:
            router.delete_deployment(id=model_id)


def _provider_from_model(model: str) -> str:
    return model.split("/", 1)[0] if "/" in model else ""


def _put_model(
    table: str,
    model_name: str,
    provider: str,
    enabled: bool,
    litellm_params: dict,
    credential_ref: str | None = None,
    pricing: dict | None = None,
) -> None:
    ddb = _dynamodb_client()
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    item = {
        "PK": {"S": "CATALOG"},
        "SK": {"S": f"MODEL#{model_name}"},
        "model_name": {"S": model_name},
        "provider": {"S": provider},
        "enabled": {"BOOL": enabled},
        "litellm_params": {"S": json.dumps(litellm_params)},
        "createdAt": {"S": now},
        "updatedAt": {"S": now},
    }
    if credential_ref:
        item["credentialRef"] = {"S": credential_ref}
    if pricing:
        item["pricing"] = {"S": json.dumps(pricing)}
    ddb.put_item(TableName=table, Item=item)


def _delete_model(table: str, model_name: str) -> None:
    ddb = _dynamodb_client()
    ddb.delete_item(
        TableName=table,
        Key={"PK": {"S": "CATALOG"}, "SK": {"S": f"MODEL#{model_name}"}},
    )


def _put_provider(table: str, provider: str, credential_ref: str) -> None:
    ddb = _dynamodb_client()
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    ddb.put_item(
        TableName=table,
        Item={
            "PK": {"S": "PROVIDER"},
            "SK": {"S": f"PROVIDER#{provider}"},
            "provider": {"S": provider},
            "credentialRef": {"S": credential_ref},
            "updatedAt": {"S": now},
        },
    )


def _read_providers(table: str) -> list[dict]:
    ddb = _dynamodb_client()
    providers: list[dict] = []
    paginator = ddb.get_paginator("query")
    for page in paginator.paginate(
        TableName=table,
        KeyConditionExpression="PK = :pk",
        ExpressionAttributeValues={":pk": {"S": "PROVIDER"}},
    ):
        for item in page.get("Items", []):
            providers.append(
                {
                    "provider": item.get("provider", {}).get("S", ""),
                    "credentialRef": item.get("credentialRef", {}).get("S", ""),
                }
            )
    return providers


def _register_admin_routes(proxy_server) -> None:
    from fastapi import Depends, HTTPException, Request
    from pydantic import BaseModel

    app = proxy_server.app

    def _require_admin(request: Request) -> None:
        key = os.environ.get("ADMIN_KEY", "")
        if not key:
            raise HTTPException(status_code=503, detail="ADMIN_KEY not configured")
        auth = request.headers.get("authorization", "")
        if auth != f"Bearer {key}":
            raise HTTPException(status_code=401, detail="unauthorized")

    def _table() -> str:
        table = os.environ.get("MODELS_TABLE")
        if not table:
            raise HTTPException(status_code=503, detail="MODELS_TABLE not configured")
        return table

    class ModelIn(BaseModel):
        model_name: str
        litellm_params: dict
        enabled: bool = True
        credentialRef: str | None = None
        pricing: dict | None = None

    class ModelPatch(BaseModel):
        litellm_params: dict | None = None
        enabled: bool | None = None
        credentialRef: str | None = None
        pricing: dict | None = None

    class ProviderIn(BaseModel):
        provider: str
        credentialRef: str | None = None

    @app.get("/admin/models", dependencies=[Depends(_require_admin)])
    async def list_models():
        _table()
        return {"models": _get_catalog(force=True)}

    @app.post("/admin/models", dependencies=[Depends(_require_admin)], status_code=201)
    async def add_model(body: ModelIn):
        table = _table()
        model = body.litellm_params.get("model", "")
        if not model:
            raise HTTPException(status_code=400, detail="litellm_params.model is required")
        provider = _provider_from_model(model)
        _put_model(
            table,
            body.model_name,
            provider,
            body.enabled,
            body.litellm_params,
            credential_ref=body.credentialRef,
            pricing=body.pricing,
        )
        _invalidate_cache()
        if body.enabled:
            _upsert_router(proxy_server, body.model_name, body.litellm_params)
        return {"model_name": body.model_name, "provider": provider, "enabled": body.enabled}

    @app.patch("/admin/models/{name}", dependencies=[Depends(_require_admin)])
    async def patch_model(name: str, body: ModelPatch):
        table = _table()
        catalog = _get_catalog(force=True)
        current = next((m for m in catalog if m["model_name"] == name), None)
        if current is None:
            raise HTTPException(status_code=404, detail="model not found")
        litellm_params = (
            body.litellm_params if body.litellm_params is not None else current["litellm_params"]
        )
        enabled = body.enabled if body.enabled is not None else current["enabled"]
        credential_ref = (
            body.credentialRef if body.credentialRef is not None else current.get("credentialRef")
        )
        pricing = body.pricing if body.pricing is not None else current.get("pricing")
        provider = _provider_from_model(litellm_params.get("model", ""))
        _put_model(
            table,
            name,
            provider,
            enabled,
            litellm_params,
            credential_ref=credential_ref,
            pricing=pricing,
        )
        _invalidate_cache()
        if enabled:
            _upsert_router(proxy_server, name, litellm_params)
        else:
            _delete_router(proxy_server, name)
        return {"model_name": name, "provider": provider, "enabled": enabled}

    @app.delete("/admin/models/{name}", dependencies=[Depends(_require_admin)], status_code=204)
    async def delete_model(name: str):
        table = _table()
        catalog = _get_catalog(force=True)
        current = next((m for m in catalog if m["model_name"] == name), None)
        if current is None:
            raise HTTPException(status_code=404, detail="model not found")
        _delete_model(table, name)
        _invalidate_cache()
        _delete_router(proxy_server, name)

    @app.get("/admin/providers", dependencies=[Depends(_require_admin)])
    async def list_providers():
        table = _table()
        return {"providers": _read_providers(table)}

    @app.post("/admin/providers", dependencies=[Depends(_require_admin)], status_code=201)
    async def add_provider(body: ProviderIn):
        table = _table()
        if not body.provider:
            raise HTTPException(status_code=400, detail="provider is required")
        if not body.credentialRef:
            raise HTTPException(status_code=400, detail="credentialRef is required")
        _put_provider(table, body.provider, body.credentialRef)
        return {"provider": body.provider, "credentialRef": body.credentialRef}

    @app.get("/admin/health", dependencies=[Depends(_require_admin)])
    async def admin_health():
        router = proxy_server.llm_router
        return {
            "ok": True,
            "router_ready": router is not None,
            "model_count": len(router.get_model_list()) if router else 0,
        }


def main() -> None:
    _load_secrets_from_ssm()
    config = build_config()
    with open(RUNTIME_CONFIG_PATH, "w") as f:
        yaml.dump(config, f)
    os.environ["CONFIG_FILE_PATH"] = RUNTIME_CONFIG_PATH

    import litellm.proxy.proxy_server as proxy_server

    _register_admin_routes(proxy_server)

    import uvicorn

    uvicorn.run(proxy_server.app, host="0.0.0.0", port=PORT)


if __name__ == "__main__":
    main()
