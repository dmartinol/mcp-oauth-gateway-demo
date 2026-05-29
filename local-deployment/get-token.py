#!/usr/bin/env python3
"""
Obtains an access token from the MCP Auth Adapter via Authorization Code + PKCE.
Steps:
  1. Fetch OIDC discovery to find endpoints
  2. DCR to get a client_id
  3. Build auth URL with PKCE, open browser
  4. Capture code via local callback server
  5. Exchange code for token, print access token to stdout
"""
import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import threading
import urllib.parse
import urllib.request
import webbrowser


def fetch_json(url: str, method: str = "GET", data: bytes | None = None, headers: dict | None = None) -> dict:
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


def pkce_pair() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(48)
    digest = hashlib.sha256(verifier.encode()).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
    return verifier, challenge


class CallbackHandler(http.server.BaseHTTPRequestHandler):
    code: str | None = None
    error: str | None = None

    def do_GET(self):
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        CallbackHandler.code = (params.get("code") or [None])[0]
        CallbackHandler.error = (params.get("error_description") or params.get("error") or [None])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(b"<h2>Authorization complete. You can close this tab.</h2>")

    def log_message(self, *_):
        pass  # suppress request logs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mcp-auth-base", default="https://mcp-auth.api.redhat.com")
    parser.add_argument("--callback-port", type=int, default=9090)
    args = parser.parse_args()

    base = args.mcp_auth_base.rstrip("/")
    redirect_uri = f"http://localhost:{args.callback_port}/callback"

    # Step 1: OIDC discovery
    print(f"Fetching OIDC config from {base}...", file=sys.stderr)
    oidc = fetch_json(f"{base}/.well-known/openid-configuration")
    authorization_endpoint = oidc["authorization_endpoint"]
    token_endpoint = oidc["token_endpoint"]
    registration_endpoint = oidc["registration_endpoint"]

    # Step 2: DCR
    print("Registering client via DCR...", file=sys.stderr)
    reg_body = json.dumps({
        "client_name": "mcp-client",
        "grant_types": ["authorization_code", "refresh_token"],
        "redirect_uris": [redirect_uri],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none",
    }).encode()
    reg = fetch_json(registration_endpoint, method="POST", data=reg_body,
                     headers={"Content-Type": "application/json"})
    client_id = reg["client_id"]
    print(f"client_id: {client_id}", file=sys.stderr)

    # Step 3: build auth URL with PKCE
    verifier, challenge = pkce_pair()
    state = secrets.token_urlsafe(16)
    params = urllib.parse.urlencode({
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": "openid offline_access",
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    })
    auth_url = f"{authorization_endpoint}?{params}"

    # Step 4: local callback server
    server = http.server.HTTPServer(("localhost", args.callback_port), CallbackHandler)
    thread = threading.Thread(target=server.handle_request)  # handles exactly one request
    thread.start()

    print(f"\nOpening browser for login. If it doesn't open, visit:\n  {auth_url}\n", file=sys.stderr)
    webbrowser.open(auth_url)
    thread.join(timeout=120)
    server.server_close()

    if CallbackHandler.error:
        print(f"Authorization failed: {CallbackHandler.error}", file=sys.stderr)
        sys.exit(1)
    if not CallbackHandler.code:
        print("No authorization code received (timeout?).", file=sys.stderr)
        sys.exit(1)

    # Step 5: exchange code for token
    token_body = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "code": CallbackHandler.code,
        "redirect_uri": redirect_uri,
        "client_id": client_id,
        "code_verifier": verifier,
    }).encode()
    token = fetch_json(token_endpoint, method="POST", data=token_body,
                       headers={"Content-Type": "application/x-www-form-urlencoded"})

    access_token = token.get("access_token")
    if not access_token:
        print(f"Token exchange failed: {token}", file=sys.stderr)
        sys.exit(1)

    print("Authorized.", file=sys.stderr)
    print(access_token)  # stdout — captured by start.sh


if __name__ == "__main__":
    main()
