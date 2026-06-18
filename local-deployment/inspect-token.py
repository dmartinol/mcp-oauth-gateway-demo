#!/usr/bin/env python3
"""Decode and print JWT claims from token-response.json or TOKEN env."""
import argparse
import base64
import json
import os
import sys

IDENTITY_KEYS = (
    "rh-org-id",
    "rh-user-id",
    "organization",
    "account_id",
    "account_number",
    "org_id",
    "sub",
)

# JWT claims that identify which authorization server / OAuth client issued the token.
AUTH_SERVER_KEYS = (
    "iss",
    "azp",
    "aud",
    "typ",
    "sid",
)

KNOWN_CLIENTS = {
    "mcp-client": "MCP Auth Adapter (get-token.py / Cursor)",
    "ocm-cli": "ocm-cli (ocm login)",
}


def decode_jwt_payload(jwt: str) -> dict:
    part = jwt.split(".")[1]
    part += "=" * (-len(part) % 4)
    return json.loads(base64.urlsafe_b64decode(part))


def infer_sso_environment(issuer: str | None) -> str:
    if not issuer:
        return "MISSING"
    if "sso.stage.redhat.com" in issuer:
        return "stage"
    if "sso.redhat.com" in issuer:
        return "production"
    return "unknown"


def print_auth_server(label: str, claims: dict) -> None:
    issuer = claims.get("iss")
    azp = claims.get("azp")

    print(f"auth server ({label}):")
    for key in AUTH_SERVER_KEYS:
        print(f"  {key}: {claims.get(key, 'MISSING')}")
    print(f"  sso_environment: {infer_sso_environment(issuer if isinstance(issuer, str) else None)}")
    if isinstance(azp, str) and azp in KNOWN_CLIENTS:
        print(f"  inferred_source: {KNOWN_CLIENTS[azp]}")
    elif isinstance(azp, str):
        print(f"  inferred_source: OAuth client '{azp}'")
    else:
        print("  inferred_source: MISSING")

    mcp_auth_base = os.environ.get("MCP_AUTH_BASE")
    sso_issuer_url = os.environ.get("SSO_ISSUER_URL")
    if mcp_auth_base or sso_issuer_url:
        print("  expected (from env):")
        if mcp_auth_base:
            print(f"    MCP_AUTH_BASE: {mcp_auth_base}")
        if sso_issuer_url:
            match = issuer == sso_issuer_url if isinstance(issuer, str) else False
            print(f"    SSO_ISSUER_URL: {sso_issuer_url} ({'match' if match else 'mismatch'})")


def print_roles(label: str, claims: dict) -> None:
    roles = claims.get("roles")
    if roles is None and isinstance(claims.get("realm_access"), dict):
        roles = claims["realm_access"].get("roles")

    print(f"roles ({label}):")
    if roles is None:
        print("  MISSING")
    elif isinstance(roles, list):
        for role in roles:
            print(f"  - {role}")
    else:
        print(json.dumps(roles, indent=2))


def inspect_token(label: str, jwt: str) -> None:
    claims = decode_jwt_payload(jwt)
    print(f"=== {label} ===")
    print_auth_server(label, claims)
    print("scope:", claims.get("scope", "MISSING"))
    print_roles(label, claims)
    if "realm_access" in claims:
        print("realm_access:", json.dumps(claims["realm_access"], indent=2))
    for key in IDENTITY_KEYS:
        value = claims.get(key, "MISSING")
        print(f"{key}: {value}")
    print()


def main() -> None:
    parser = argparse.ArgumentParser(description="Inspect OAuth JWT claims")
    parser.add_argument(
        "--file",
        default="token-response.json",
        help="Token response JSON (default: token-response.json)",
    )
    args = parser.parse_args()

    if os.environ.get("TOKEN"):
        inspect_token("TOKEN", os.environ["TOKEN"])
        return

    path = args.file
    if not os.path.isfile(path):
        print(f"File not found: {path}", file=sys.stderr)
        print("Set TOKEN env or pass --file to a token response JSON.", file=sys.stderr)
        sys.exit(1)

    with open(path) as f:
        resp = json.load(f)

    print(f"response scope: {resp.get('scope', 'MISSING')}\n")
    for label in ("access_token", "id_token", "refresh_token"):
        if label in resp:
            inspect_token(label, resp[label])


if __name__ == "__main__":
    main()
