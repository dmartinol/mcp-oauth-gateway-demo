#!/usr/bin/env bash
# Configure gateway OAuth: PRM on MCPGatewayExtension + JWT AuthPolicy.
# Chart 0.7.0+ owns the broker deployment — kubectl set env is reverted on reconcile.
# PRM (MCP_AUTH_BASE) and AuthPolicy (SSO_ISSUER_URL) must come from the same env file when Kuadrant is installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=public-url.sh
source "${SCRIPT_DIR}/public-url.sh"

MCP_GATEWAY_EXTENSION_NAME="${MCP_GATEWAY_EXTENSION_NAME:-mcp-gateway-extension}"
MCP_AUTH_BASE="${MCP_AUTH_BASE:?MCP_AUTH_BASE is required — source ../env.prod or ../env.stage}"
OAUTH_SCOPES_SUPPORTED="${OAUTH_SCOPES_SUPPORTED:-api.console,api.ocm,openid,offline_access}"

export MCP_AUTH_BASE OAUTH_SCOPES_SUPPORTED MCP_RESOURCE_URL

patch_payload="$(python3 - <<'PY'
import json, os

scopes = [s.strip() for s in os.environ["OAUTH_SCOPES_SUPPORTED"].split(",") if s.strip()]
print(json.dumps({
    "spec": {
        "oauthProtectedResource": {
            "resourceName": "Red Hat MCP Gateway",
            "resource": os.environ["MCP_RESOURCE_URL"],
            "authorizationServers": [os.environ["MCP_AUTH_BASE"]],
            "bearerMethodsSupported": ["header"],
            "scopesSupported": scopes,
        }
    }
}))
PY
)"

echo "==> Configuring OAuth Protected Resource metadata on ${MCP_GATEWAY_EXTENSION_NAME}..." >&2
echo "    resource: ${MCP_RESOURCE_URL}" >&2
kubectl patch "mcpgatewayextension/${MCP_GATEWAY_EXTENSION_NAME}" -n mcp-system \
  --type merge -p "${patch_payload}"

kubectl rollout status deployment/mcp-gateway -n mcp-system --timeout=120s

"${SCRIPT_DIR}/apply-authpolicy.sh"
