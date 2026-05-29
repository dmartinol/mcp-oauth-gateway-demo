#!/usr/bin/env bash
# Obtains an access token via the MCP Auth Adapter using Authorization Code + PKCE.
# Starts a local callback server, opens the browser, exchanges the code for a token.
# Outputs the access token on stdout; progress goes to stderr.
set -euo pipefail

MCP_AUTH_BASE="${MCP_AUTH_BASE:-https://mcp-auth.api.redhat.com}"
CALLBACK_PORT="${CALLBACK_PORT:-9090}"

exec python3 "$(dirname "$0")/get-token.py" \
  --mcp-auth-base "${MCP_AUTH_BASE}" \
  --callback-port "${CALLBACK_PORT}"
