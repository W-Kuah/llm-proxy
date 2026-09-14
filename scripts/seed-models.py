#!/usr/bin/env python3
"""Seed the DynamoDB model catalog from config.yaml.

One-off migration: reads the model_list in config.yaml and writes each model as
a DynamoDB item (PK=CATALOG, SK=MODEL#<name>). Run once after `terraform apply`
creates the table. Idempotent — re-running overwrites the seeded models.

Usage:
    MODELS_TABLE=llm-proxy-models AWS_REGION=ap-southeast-2 python3 scripts/seed-models.py
"""

import json
import os
import sys
import time
from pathlib import Path

import boto3
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = REPO_ROOT / "config.yaml"


def provider_from_model(model: str) -> str:
    """Derive the provider from the litellm model prefix (before the first '/')."""
    return model.split("/", 1)[0] if "/" in model else ""


def main() -> None:
    table = os.environ.get("MODELS_TABLE")
    region = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION"))
    if not table:
        print("ERROR: MODELS_TABLE not set", file=sys.stderr)
        sys.exit(1)

    config = yaml.safe_load(CONFIG_PATH.read_text())
    model_list = config.get("model_list", [])

    ddb = boto3.client("dynamodb", region_name=region)
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    for entry in model_list:
        model_name = entry["model_name"]
        litellm_params = entry.get("litellm_params", {})
        provider = provider_from_model(litellm_params.get("model", ""))

        item = {
            "PK": {"S": "CATALOG"},
            "SK": {"S": f"MODEL#{model_name}"},
            "model_name": {"S": model_name},
            "provider": {"S": provider},
            "enabled": {"BOOL": True},
            "litellm_params": {"S": json.dumps(litellm_params)},
            "createdAt": {"S": now},
            "updatedAt": {"S": now},
        }

        ddb.put_item(TableName=table, Item=item)
        print(f"seeded {model_name} ({provider})")

    print(f"Done: {len(model_list)} models written to {table}")


if __name__ == "__main__":
    main()
