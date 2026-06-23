#!/usr/bin/env bash
# Re-point the gateway OAuth URLs and listener hostname at a new public endpoint.
#
# Local HTTP (default):
#   MCP_PUBLIC_HOST=localhost MCP_PUBLIC_PORT=8001 ./reconfigure-public-host.sh
#
# ngrok / HTTPS tunnel:
#   MCP_PUBLIC_URL=https://xyz.ngrok-free.app/mcp ./reconfigure-public-host.sh
#   (tunnel with: ngrok http 8001)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=public-url.sh
source "${SCRIPT_DIR}/public-url.sh"

MCP_GATEWAY_VERSION="${MCP_GATEWAY_VERSION:-0.7.0}"

echo "==> Setting gateway listener hostname to ${MCP_PUBLIC_HOST}..." >&2
echo "    MCP resource: ${MCP_RESOURCE_URL}" >&2
helm upgrade mcp-gateway oci://ghcr.io/kuadrant/charts/mcp-gateway \
  --version "${MCP_GATEWAY_VERSION}" \
  --namespace mcp-system \
  --reuse-values \
  --set "gateway.publicHost=${MCP_PUBLIC_HOST}"

"${SCRIPT_DIR}/configure-oauth-metadata.sh"

echo "==> Applying oauth-metadata HTTPRoute..." >&2
sed -e "s|__MCP_PUBLIC_HOST__|${MCP_PUBLIC_HOST}|g" \
  "${SCRIPT_DIR}/manifests/oauth-metadata-httproute.yaml" | kubectl apply -f -

echo "" >&2
echo "Done. Update ~/.cursor/mcp.json:" >&2
echo '  {"mcpServers":{"mcp-gateway":{"url":"'"${MCP_RESOURCE_URL}"'"}}}' >&2
echo "" >&2
echo "Verify:" >&2
echo "  curl -sS ${MCP_PRM_URL} | jq ." >&2
