"""Tenant identity: Cognito tokens, verified properly.

Tokens are verified against the user pool's JWKS (RS256), not merely decoded.
Decoding alone would let anyone mint a token claiming any tenant's `sub` and
read another tenant's data, so the signature check is the thing actually
holding multi-tenancy together at the application layer.
"""
import os
import time

import jwt
from jwt import PyJWKClient

COGNITO_ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "").rstrip("/")
USER_POOL_ID = os.environ["COGNITO_USER_POOL_ID"]
CLIENT_ID = os.environ["COGNITO_CLIENT_ID"]

# On real AWS the issuer is https://cognito-idp.<region>.amazonaws.com/<pool>.
# Against the emulator it is <endpoint>/<pool>. Configurable for that reason.
ISSUER = os.environ.get("COGNITO_ISSUER") or f"{COGNITO_ENDPOINT}/{USER_POOL_ID}"
JWKS_URL = os.environ.get("COGNITO_JWKS_URL") or f"{ISSUER}/.well-known/jwks.json"

_jwk_client = None
_jwk_client_at = 0.0


def _jwks():
    """PyJWKClient caches keys itself; rebuild hourly so key rotation is picked up."""
    global _jwk_client, _jwk_client_at
    if _jwk_client is None or (time.time() - _jwk_client_at) > 3600:
        _jwk_client = PyJWKClient(JWKS_URL)
        _jwk_client_at = time.time()
    return _jwk_client


class AuthError(Exception):
    def __init__(self, message, status=401):
        super().__init__(message)
        self.message = message
        self.status = status


def verify_token(authorization_header):
    """Return the verified claims of a Cognito ID token, or raise AuthError."""
    if not authorization_header or not authorization_header.startswith("Bearer "):
        raise AuthError("missing bearer token")
    token = authorization_header.split(" ", 1)[1].strip()
    try:
        signing_key = _jwks().get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=CLIENT_ID,      # must have been issued for THIS app client
            options={"require": ["exp", "sub", "aud"]},
        )
    except jwt.ExpiredSignatureError:
        raise AuthError("token expired")
    except Exception as e:
        # Covers bad signature, unknown kid, wrong audience, malformed token.
        raise AuthError(f"invalid token: {type(e).__name__}")

    # Cognito issues both access and id tokens; only the id token carries the
    # user attributes we key tenants on.
    if claims.get("token_use") != "id":
        raise AuthError("expected an id token")
    if USER_POOL_ID not in claims.get("iss", ""):
        raise AuthError("token issued by a different user pool")
    return claims
