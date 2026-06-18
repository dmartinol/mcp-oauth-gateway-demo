#!/usr/bin/env bash
# Re-point the gateway OAuth URLs and listener hostname at a new MCP_PUBLIC_HOST.
# Use this to migrate an existing cluster from mcp.127-0-0-1.sslip.io to localhost
# so Cursor's Chromium stack does not HTTPS-upgrade the discovery chain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MCP_GATEWAY_VERSION="${MCP_GATEWAY_VERSION:-0.7.0}"
MCP_PUBLIC_HOST="${MCP_PUBLIC_HOST:-localhost}"
MCP_PUBLIC_PORT="${MCP_PUBLIC_PORT:-8001}"
MCP_AUTH_BASE="${MCP_AUTH_BASE:-https://mcp-auth.stage.api.redhat.com}"
SSO_ISSUER_URL="${SSO_ISSUER_URL:-https://sso.stage.redhat.com/auth/realms/redhat-external}"
OAUTH_SCOPES_SUPPORTED="${OAUTH_SCOPES_SUPPORTED:-api.console,api.ocm,openid,offline_access}"

echo "==> Setting gateway listener hostname to ${MCP_PUBLIC_HOST}..." >&2
helm upgrade mcp-gateway oci://ghcr.io/kuadrant/charts/mcp-gateway \
  --version "${MCP_GATEWAY_VERSION}" \
  --namespace mcp-system \
  --reuse-values \
  --set "gateway.publicHost=${MCP_PUBLIC_HOST}"

"${SCRIPT_DIR}/configure-oauth-metadata.sh"

echo "==> Applying AuthPolicy and oauth-metadata HTTPRoute..." >&2
"${SCRIPT_DIR}/apply-authpolicy.sh"

sed -e "s|__MCP_PUBLIC_HOST__|${MCP_PUBLIC_HOST}|g" \
  "${SCRIPT_DIR}/manifests/oauth-metadata-httproute.yaml" | kubectl apply -f -

echo "" >&2
echo "Done. Update ~/.cursor/mcp.json:" >&2
echo '  {"mcpServers":{"mcp-gateway-kind":{"url":"http://'"${MCP_PUBLIC_HOST}"':'"${MCP_PUBLIC_PORT}"'/mcp"}}}' >&2
echo "" >&2
echo "Verify:" >&2
echo "  curl -sS http://${MCP_PUBLIC_HOST}:${MCP_PUBLIC_PORT}/.well-known/oauth-protected-resource | jq ." >&2
