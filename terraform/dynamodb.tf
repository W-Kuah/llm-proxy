# Runtime model catalog. Models are data, not config: the Lambda reads this
# table at runtime (cached ~60s) and builds the LiteLLM router from it, so
# adding/removing/enabling a model is a data write, not a redeploy.
#
# Schema:
#   PK (String): "CATALOG"            — constant shared partition; one Query
#                                       returns the whole catalog (no Scan/GSI).
#   SK (String): "MODEL#<model_name>" — sort key, one item per model.
#   Attributes: model_name, provider, credentialRef, enabled, litellm_params,
#               pricing, createdAt, updatedAt.
#
# The same table also stores provider credential refs under a second partition:
#   PK (String): "PROVIDER"             — provider metadata partition.
#   SK (String): "PROVIDER#<provider>"  — one item per provider.
#   Attributes: provider, credentialRef, updatedAt.

resource "aws_dynamodb_table" "models" {
  name         = local.models_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}
