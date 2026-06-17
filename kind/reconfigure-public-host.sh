#!/usr/bin/env bash
# Re-point the gateway OAuth URLs and listener hostname at a new MCP_PUBLIC_HOST.
# Use this to migrate an existing cluster from mcp.127-0-0-1.sslip.io to localhost
# so Cursor's Chromium stack does not HTTPS-upgrade the discovery chain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MCP_GATEWAY_VERSION="${MCP_GATEWAY_VERSION:-0.6.1}"
MCP_PUBLIC_HOST="${MCP_PUBLIC_HOST:-localhost}"
MCP_PUBLIC_PORT="${MCP_PUBLIC_PORT:-8001}"
MCP_AUTH_BASE="${MCP_AUTH_BASE:-https://mcp-auth.stage.api.redhat.com}"
SSO_ISSUER_URL="${SSO_ISSUER_URL:-https://sso.stage.redhat.com/auth/realms/redhat-external}"

echo "==> Setting gateway listener hostname to ${MCP_PUBLIC_HOST}..." >&2
helm upgrade mcp-gateway oci://ghcr.io/kuadrant/charts/mcp-gateway \
  --version "${MCP_GATEWAY_VERSION}" \
  --namespace mcp-system \
  --reuse-values \
  --set "gateway.publicHost=${MCP_PUBLIC_HOST}"

echo "==> Updating OAuth protected-resource metadata..." >&2
kubectl set env deployment/mcp-gateway -n mcp-system \
  OAUTH_RESOURCE_NAME="Red Hat MCP Gateway" \
  OAUTH_RESOURCE="http://${MCP_PUBLIC_HOST}:${MCP_PUBLIC_PORT}/mcp" \
  OAUTH_AUTHORIZATION_SERVERS="${MCP_AUTH_BASE}" \
  OAUTH_BEARER_METHODS_SUPPORTED="header" \
  OAUTH_SCOPES_SUPPORTED="openid,roles,id.roles,offline_access"

kubectl rollout status deployment/mcp-gateway -n mcp-system --timeout=120s

echo "==> Applying AuthPolicy and oauth-metadata HTTPRoute..." >&2
sed -e "s|https://sso.redhat.com/auth/realms/redhat-external|${SSO_ISSUER_URL}|" \
    -e "s|__MCP_PUBLIC_HOST__|${MCP_PUBLIC_HOST}|g" \
    -e "s|__MCP_PUBLIC_PORT__|${MCP_PUBLIC_PORT}|g" \
  "${SCRIPT_DIR}/manifests/authpolicy.yaml" | kubectl apply -f -

sed -e "s|__MCP_PUBLIC_HOST__|${MCP_PUBLIC_HOST}|g" \
  "${SCRIPT_DIR}/manifests/oauth-metadata-httproute.yaml" | kubectl apply -f -

echo "" >&2
echo "Done. Update ~/.cursor/mcp.json:" >&2
echo '  {"mcpServers":{"mcp-gateway-kind":{"url":"http://'"${MCP_PUBLIC_HOST}"':'"${MCP_PUBLIC_PORT}"'/mcp"}}}' >&2
echo "" >&2
echo "Verify:" >&2
echo "  curl -sS http://${MCP_PUBLIC_HOST}:${MCP_PUBLIC_PORT}/.well-known/oauth-protected-resource | jq ." >&2
