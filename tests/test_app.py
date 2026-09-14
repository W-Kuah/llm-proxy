import os
import sys
from unittest.mock import patch

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import app


def test_provider_from_model():
    assert app._provider_from_model("together_ai/meta-llama/Llama-3.3-70B") == "together_ai"
    assert app._provider_from_model("bedrock/us.anthropic.claude-3-5-sonnet") == "bedrock"
    assert app._provider_from_model("no-prefix") == ""


def test_build_model_list_filters_disabled():
    catalog = [
        {"model_name": "a", "litellm_params": {"model": "x"}, "enabled": True},
        {"model_name": "b", "litellm_params": {"model": "y"}, "enabled": False},
        {"model_name": "c", "litellm_params": {"model": "z"}, "enabled": True},
    ]
    assert app._build_model_list(catalog) == [
        {"model_name": "a", "litellm_params": {"model": "x"}},
        {"model_name": "c", "litellm_params": {"model": "z"}},
    ]


def test_resolve_litellm_params_resolves_os_environ_refs():
    fake = lambda s: "resolved:" + s
    params = {
        "model": "together_ai/foo",
        "api_key": "os.environ/TOGETHER_API_KEY",
        "max_tokens": 100,
    }
    result = app._resolve_litellm_params(params, get_secret=fake)
    assert result["model"] == "together_ai/foo"
    assert result["api_key"] == "resolved:os.environ/TOGETHER_API_KEY"
    assert result["max_tokens"] == 100


@mock_aws
def test_get_catalog_cache_ttl(monkeypatch):
    monkeypatch.setenv("MODELS_TABLE", "test-models")
    monkeypatch.setenv("AWS_REGION", "us-east-1")

    ddb = boto3.client("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName="test-models",
        KeySchema=[
            {"AttributeName": "PK", "KeyType": "HASH"},
            {"AttributeName": "SK", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "PK", "AttributeType": "S"},
            {"AttributeName": "SK", "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )
    ddb.put_item(
        TableName="test-models",
        Item={
            "PK": {"S": "CATALOG"},
            "SK": {"S": "MODEL#a"},
            "model_name": {"S": "a"},
            "provider": {"S": "together_ai"},
            "enabled": {"BOOL": True},
            "litellm_params": {"S": '{"model": "together_ai/foo"}'},
        },
    )

    app._invalidate_cache()

    with patch("app.time.time", return_value=1000.0):
        first = app._get_catalog()
    assert len(first) == 1

    ddb.put_item(
        TableName="test-models",
        Item={
            "PK": {"S": "CATALOG"},
            "SK": {"S": "MODEL#b"},
            "model_name": {"S": "b"},
            "provider": {"S": "together_ai"},
            "enabled": {"BOOL": True},
            "litellm_params": {"S": '{"model": "together_ai/bar"}'},
        },
    )

    with patch("app.time.time", return_value=1000.0 + app.CATALOG_TTL - 1):
        cached = app._get_catalog()
    assert len(cached) == 1

    with patch("app.time.time", return_value=1000.0 + app.CATALOG_TTL + 1):
        refreshed = app._get_catalog()
    assert len(refreshed) == 2


@mock_aws
def test_provider_round_trip(monkeypatch):
    monkeypatch.setenv("MODELS_TABLE", "test-models")
    monkeypatch.setenv("AWS_REGION", "us-east-1")

    ddb = boto3.client("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName="test-models",
        KeySchema=[
            {"AttributeName": "PK", "KeyType": "HASH"},
            {"AttributeName": "SK", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "PK", "AttributeType": "S"},
            {"AttributeName": "SK", "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )

    app._put_provider("test-models", "together_ai", "/llm-proxy/dev/TOGETHER_API_KEY")
    providers = app._read_providers("test-models")
    assert providers == [
        {"provider": "together_ai", "credentialRef": "/llm-proxy/dev/TOGETHER_API_KEY"}
    ]


@mock_aws
def test_model_credential_ref_and_pricing_round_trip(monkeypatch):
    monkeypatch.setenv("MODELS_TABLE", "test-models")
    monkeypatch.setenv("AWS_REGION", "us-east-1")

    ddb = boto3.client("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName="test-models",
        KeySchema=[
            {"AttributeName": "PK", "KeyType": "HASH"},
            {"AttributeName": "SK", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "PK", "AttributeType": "S"},
            {"AttributeName": "SK", "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )

    app._put_model(
        "test-models",
        "m",
        "together_ai",
        True,
        {"model": "together_ai/foo"},
        credential_ref="/llm-proxy/dev/TOGETHER_API_KEY",
        pricing={"input_cost_per_token": 0.000001, "output_cost_per_token": 0.000003},
    )

    app._invalidate_cache()
    catalog = app._get_catalog(force=True)
    assert len(catalog) == 1
    assert catalog[0]["credentialRef"] == "/llm-proxy/dev/TOGETHER_API_KEY"
    assert catalog[0]["pricing"] == {
        "input_cost_per_token": 0.000001,
        "output_cost_per_token": 0.000003,
    }


@mock_aws
def test_load_secrets_from_ssm(monkeypatch):
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("TOGETHER_API_KEY_SSM_NAME", "/llm-proxy/dev/TOGETHER_API_KEY")
    monkeypatch.setenv("MASTER_KEY_SSM_NAME", "/llm-proxy/dev/LITELLM_MASTER_KEY")
    monkeypatch.setenv("ADMIN_KEY_SSM_NAME", "/llm-proxy/dev/ADMIN_KEY")

    ssm = boto3.client("ssm", region_name="us-east-1")
    ssm.put_parameter(
        Name="/llm-proxy/dev/TOGETHER_API_KEY", Value="tgp_secret", Type="SecureString"
    )
    ssm.put_parameter(
        Name="/llm-proxy/dev/LITELLM_MASTER_KEY", Value="sk_master", Type="SecureString"
    )
    ssm.put_parameter(
        Name="/llm-proxy/dev/ADMIN_KEY", Value="admin_secret", Type="SecureString"
    )

    app._load_secrets_from_ssm()

    assert os.environ["TOGETHER_API_KEY"] == "tgp_secret"
    assert os.environ["LITELLM_MASTER_KEY"] == "sk_master"
    assert os.environ["ADMIN_KEY"] == "admin_secret"


@mock_aws
def test_load_secrets_from_ssm_noop_without_names(monkeypatch):
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.delenv("TOGETHER_API_KEY_SSM_NAME", raising=False)
    monkeypatch.delenv("MASTER_KEY_SSM_NAME", raising=False)
    monkeypatch.delenv("ADMIN_KEY_SSM_NAME", raising=False)
    monkeypatch.delenv("TOGETHER_API_KEY", raising=False)

    app._load_secrets_from_ssm()

    assert "TOGETHER_API_KEY" not in os.environ
