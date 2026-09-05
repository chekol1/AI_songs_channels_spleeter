# ---------------------------------------------------------------------------
# Tenant identity.
#
# Each signed-up user is a tenant. The Cognito `sub` claim is the tenant key
# used everywhere else: the tenants table, the S3 key prefix, and every job
# query. The API verifies token signatures against this pool's JWKS, so a
# forged or unsigned token is rejected rather than trusted.
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "tenants" {
  name = "sonicloud-tenants"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_uppercase = false
    require_symbols   = false
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "sonicloud-web"
  user_pool_id = aws_cognito_user_pool.tenants.id

  # No client secret: the browser is a public client.
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.tenants.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.web.id
}
