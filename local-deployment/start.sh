#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Configuration ────────────────────────────────────────────────────────────

# GATEWAY_SIGNING_KEY: required. Must be at least 32 bytes.
# Generate once and keep stable across restarts to preserve sessions.
: "${GATEWAY_SIGNING_KEY:?GATEWAY_SIGNING_KEY must be set. Run: export GATEWAY_SIGNING_KEY=\$(openssl rand -hex 32)}"

# MCP Auth Adapter — authorization server advertised to MCP clients.
# Implements DCR and proxies to Red Hat SSO. MCP clients register dynamically
# and get a token via device flow without needing pre-issued credentials.
MCP_AUTH_BASE="${MCP_AUTH_BASE:-https://mcp-auth.api.redhat.com}"

# Log level: -4=debug, 0=info (default), 4=warn, 8=error
LOG_LEVEL="${LOG_LEVEL:-0}"

# Broker port — must differ from insights-mcp (default 8080)
BROKER_PORT="${BROKER_PORT:-8081}"

# Public host: what MCP clients connect to (Envoy listener)
MCP_PUBLIC_HOST="${MCP_PUBLIC_HOST:-localhost:8888}"

# Internal host: used by the router for hairpin initialize requests back through Envoy
MCP_PRIVATE_HOST="${MCP_PRIVATE_HOST:-localhost:8888}"

chmod +x "${SCRIPT_DIR}/get-token.sh"

# ── Obtain broker access token ───────────────────────────────────────────────

echo "Obtaining access token via MCP Auth Adapter (${MCP_AUTH_BASE})..."
BROKER_TOKEN=$(MCP_AUTH_BASE="${MCP_AUTH_BASE}" "${SCRIPT_DIR}/get-token.sh")
echo "Token obtained."

# Write a runtime config with the actual token substituted in.
# config.yaml is the template; config.runtime.yaml is never committed.
RUNTIME_CONFIG="${SCRIPT_DIR}/config.runtime.yaml"
sed "s/INSIGHTS_MCP_TOKEN_PLACEHOLDER/${BROKER_TOKEN}/" "${SCRIPT_DIR}/config.yaml" > "${RUNTIME_CONFIG}"

# ── Build ────────────────────────────────────────────────────────────────────

echo "Building mcp-broker-router..."
cd "${REPO_ROOT}"
go build -o bin/mcp-broker-router ./cmd/mcp-broker-router

# ── Start Envoy ──────────────────────────────────────────────────────────────

echo "Starting Envoy container..."
podman rm -f mcp-envoy 2>/dev/null || true

podman run -d \
  --name mcp-envoy \
  --entrypoint="" \
  -p 8888:8888 \
  -v "${SCRIPT_DIR}/envoy.yaml:/etc/envoy/envoy.yaml:ro,z" \
  docker.io/envoyproxy/envoy:v1.33-latest \
  /usr/local/bin/envoy -c /etc/envoy/envoy.yaml --log-level warn

echo "Envoy started (listener: :8888)"

# ── Start broker-router ──────────────────────────────────────────────────────

echo "Starting mcp-broker-router..."
echo "  public-host:  ${MCP_PUBLIC_HOST}"
echo "  private-host: ${MCP_PRIVATE_HOST}"
echo "  auth-adapter: ${MCP_AUTH_BASE}"
echo "  config:       ${RUNTIME_CONFIG}"

GATEWAY_SIGNING_KEY="${GATEWAY_SIGNING_KEY}" \
  OAUTH_RESOURCE="http://${MCP_PUBLIC_HOST}/mcp" \
  OAUTH_AUTHORIZATION_SERVERS="${MCP_AUTH_BASE}" \
  OAUTH_SCOPES_SUPPORTED="openid,offline_access" \
  "${REPO_ROOT}/bin/mcp-broker-router" \
  --mcp-broker-public-address="0.0.0.0:${BROKER_PORT}" \
  --mcp-gateway-config="${RUNTIME_CONFIG}" \
  --mcp-gateway-public-host="${MCP_PUBLIC_HOST}" \
  --mcp-gateway-private-host="${MCP_PRIVATE_HOST}" \
  --discovery-tools-enabled=false \
  --log-level="${LOG_LEVEL}"
