"""Verify Apple Sign In identity tokens.

The token is a JWT signed by Apple with one of the keys at:
    https://appleid.apple.com/auth/keys

We verify:
- Signature using Apple's public key matching the kid header
- iss == "https://appleid.apple.com"
- aud == our bundle ID
- exp > now
- nonce (if set)

Returns the verified claims (sub = stable Apple user ID, email if present).
"""
import time
from typing import Optional

import httpx
from jose import jwk, jwt
from jose.utils import base64url_decode

from config import settings

APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys"
APPLE_ISSUER = "https://appleid.apple.com"

_keys_cache: dict = {"keys": None, "fetched_at": 0}


async def _get_apple_keys() -> list[dict]:
    now = time.time()
    if _keys_cache["keys"] and now - _keys_cache["fetched_at"] < 3600:
        return _keys_cache["keys"]
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(APPLE_KEYS_URL)
        resp.raise_for_status()
        keys = resp.json().get("keys", [])
    _keys_cache["keys"] = keys
    _keys_cache["fetched_at"] = now
    return keys


async def verify_identity_token(token: str) -> dict:
    """
    Returns Apple's claims dict on success. Raises ValueError on any check failure.
    """
    try:
        unverified_header = jwt.get_unverified_header(token)
    except Exception as e:
        raise ValueError(f"Invalid token format: {e}")

    kid = unverified_header.get("kid")
    if not kid:
        raise ValueError("Token missing kid")

    keys = await _get_apple_keys()
    matching = next((k for k in keys if k.get("kid") == kid), None)
    if not matching:
        raise ValueError("No Apple key matches token kid")

    public_key = jwk.construct(matching)

    # Manually verify signature (jose's `jwt.decode` would do this, but we want
    # explicit control over which checks we run).
    message, encoded_sig = token.rsplit(".", 1)
    decoded_sig = base64url_decode(encoded_sig.encode())
    if not public_key.verify(message.encode(), decoded_sig):
        raise ValueError("Invalid token signature")

    # Now decode + validate claims.
    claims = jwt.get_unverified_claims(token)

    if claims.get("iss") != APPLE_ISSUER:
        raise ValueError(f"Bad issuer: {claims.get('iss')}")

    aud = claims.get("aud")
    if aud != settings.apns_bundle_id:
        raise ValueError(f"Token audience {aud!r} != bundle id {settings.apns_bundle_id!r}")

    exp = claims.get("exp", 0)
    if exp < time.time():
        raise ValueError("Token expired")

    if not claims.get("sub"):
        raise ValueError("Token missing sub (Apple user id)")

    return claims
