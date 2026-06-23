#!/usr/bin/env bash
# Patch MCPGatewayExtension with OAuth Protected Resource Metadata.
# Mirrors kind/configure-oauth-metadata.sh; differences: HTTPS route, oc instead of kubectl for URL lookup.
set -euo pipefail

MCP_GATEWAY_EXTENSION_NAME="${MCP_GATEWAY_EXTENSION_NAME:-mcp-gateway-extension}"
MCP_GATEWAY_NAMESPACE="${MCP_GATEWAY_NAMESPACE:-mcp-gateway-system}"
MCP_AUTH_BASE="${MCP_AUTH_BASE:?Run: source ../env.stage  (or ../env.prod)}"
OAUTH_SCOPES_SUPPORTED="${OAUTH_SCOPES_SUPPORTED:-api.console,api.ocm,openid,offline_access}"

GATEWAY_URL=$(oc get route mcp-gateway -n mcp-gateway-system -o jsonpath='{.spec.host}')
echo "==> Gateway URL: https://$GATEWAY_URL/mcp" >&2

patch_payload="$(python3 - <<'PY'
import json, os
scopes = [s.strip() for s in os.environ["OAUTH_SCOPES_SUPPORTED"].split(",") if s.strip()]
print(json.dumps({"spec": {"oauthProtectedResource": {
    "resourceName": "Red Hat MCP Gateway",
    "resource": f"https://{os.environ['GATEWAY_URL']}/mcp",
    "authorizationServers": [os.environ["MCP_AUTH_BASE"]],
    "bearerMethodsSupported": ["header"],
    "scopesSupported": scopes,
}}}))
PY
)"

# Try patch first; if the resource doesn't exist yet, create it.
if kubectl get "mcpgatewayextension/${MCP_GATEWAY_EXTENSION_NAME}" -n "${MCP_GATEWAY_NAMESPACE}" &>/dev/null; then
    echo "==> Patching ${MCP_GATEWAY_EXTENSION_NAME}..." >&2
    kubectl patch "mcpgatewayextension/${MCP_GATEWAY_EXTENSION_NAME}" -n "${MCP_GATEWAY_NAMESPACE}" \
        --type merge -p "${patch_payload}"
else
    echo "==> MCPGatewayExtension not found — creating ${MCP_GATEWAY_EXTENSION_NAME}..." >&2
    python3 - <<'PY' | kubectl apply -f -
import json, os
scopes = [s.strip() for s in os.environ["OAUTH_SCOPES_SUPPORTED"].split(",") if s.strip()]
print(json.dumps({
    "apiVersion": "mcp.kuadrant.io/v1alpha1",
    "kind": "MCPGatewayExtension",
    "metadata": {"name": os.environ["MCP_GATEWAY_EXTENSION_NAME"], "namespace": os.environ["MCP_GATEWAY_NAMESPACE"]},
    "spec": {"oauthProtectedResource": {
        "resourceName": "Red Hat MCP Gateway",
        "resource": f"https://{os.environ['GATEWAY_URL']}/mcp",
        "authorizationServers": [os.environ["MCP_AUTH_BASE"]],
        "bearerMethodsSupported": ["header"],
        "scopesSupported": scopes,
    }},
}))
PY
fi
