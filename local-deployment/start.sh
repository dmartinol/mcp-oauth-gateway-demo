#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MCP_GATEWAY_VERSION="${MCP_GATEWAY_VERSION:-0.7.0}"
ENVOY_IMAGE="${ENVOY_IMAGE:-docker.io/envoyproxy/envoy:v1.33-latest}"

# mcp-broker-router is built from the Kuadrant/mcp-gateway source tree.
# Clone it as a sibling of this demo repo, or set MCP_GATEWAY_ROOT explicitly.
if [ -n "${MCP_GATEWAY_ROOT:-}" ]; then
  REPO_ROOT="$(cd "${MCP_GATEWAY_ROOT}" && pwd)"
else
  REPO_ROOT="${DEMO_ROOT}/../mcp-gateway"
fi

# ── Configuration ────────────────────────────────────────────────────────────

# GATEWAY_SIGNING_KEY: required. Must be at least 32 bytes.
# Generate once and keep stable across restarts to preserve sessions.
: "${GATEWAY_SIGNING_KEY:?GATEWAY_SIGNING_KEY must be set. Run: export GATEWAY_SIGNING_KEY=\$(openssl rand -hex 32)}"

# MCP Auth Adapter — authorization server advertised to MCP clients.
# Implements DCR and proxies to Red Hat SSO. MCP clients register dynamically
# and get a token via device flow without needing pre-issued credentials.
MCP_AUTH_BASE="${MCP_AUTH_BASE:-https://mcp-auth.stage.api.redhat.com}"
OAUTH_SCOPES_SUPPORTED="${OAUTH_SCOPES_SUPPORTED:-api.console,api.ocm,openid,offline_access}"

# Log level: -4=debug, 0=info (default), 4=warn, 8=error
LOG_LEVEL="${LOG_LEVEL:-0}"

# Broker port — must differ from insights-mcp (default 8080)
BROKER_PORT="${BROKER_PORT:-8081}"

# Public host: what MCP clients connect to (Envoy listener). Use MCP_LISTEN_ADDR only —
# do not inherit kind's MCP_PUBLIC_HOST (hostname without port).
MCP_LISTEN_ADDR="${MCP_LISTEN_ADDR:-localhost:8888}"
MCP_PUBLIC_HOST="${MCP_LISTEN_ADDR}"
MCP_PRIVATE_HOST="${MCP_LISTEN_ADDR}"

chmod +x "${SCRIPT_DIR}/get-token.sh"

# ── Obtain broker access token ───────────────────────────────────────────────

echo "Obtaining access token via MCP Auth Adapter (${MCP_AUTH_BASE})..."
BROKER_TOKEN=$(MCP_AUTH_BASE="${MCP_AUTH_BASE}" "${SCRIPT_DIR}/get-token.sh")
echo "Token obtained."

# Reuse the same token for Cursor (~/.cursor/mcp.json). Skip with SKIP_CURSOR_CONFIG=1.
if [ "${SKIP_CURSOR_CONFIG:-0}" != "1" ]; then
  chmod +x "${SCRIPT_DIR}/cursor-config.sh"
  MCP_ACCESS_TOKEN="${BROKER_TOKEN}" MCP_AUTH_BASE="${MCP_AUTH_BASE}" \
    MCP_URL="http://${MCP_LISTEN_ADDR}/mcp" \
    "${SCRIPT_DIR}/cursor-config.sh"
fi

# Write a runtime config with the actual token substituted in.
# config.yaml is the template; config.runtime.yaml is never committed.
RUNTIME_CONFIG="${SCRIPT_DIR}/config.runtime.yaml"
sed "s/INSIGHTS_MCP_TOKEN_PLACEHOLDER/${BROKER_TOKEN}/" "${SCRIPT_DIR}/config.yaml" > "${RUNTIME_CONFIG}"

# ── Build ────────────────────────────────────────────────────────────────────

if [ ! -f "${REPO_ROOT}/go.mod" ]; then
  cat >&2 <<EOF
mcp-gateway source not found at: ${REPO_ROOT}

Clone it next to this demo repo (or set MCP_GATEWAY_ROOT):

  git clone https://github.com/Kuadrant/mcp-gateway.git "${DEMO_ROOT}/../mcp-gateway"
  cd "${DEMO_ROOT}/../mcp-gateway" && git checkout "v${MCP_GATEWAY_VERSION}"

Then rerun ./start.sh
EOF
  exit 1
fi

echo "Building mcp-broker-router from ${REPO_ROOT}..."
mkdir -p "${SCRIPT_DIR}/bin"
cd "${REPO_ROOT}"
go build -o "${SCRIPT_DIR}/bin/mcp-broker-router" ./cmd/mcp-broker-router

# ── Start Envoy ──────────────────────────────────────────────────────────────

echo "Starting Envoy container..."
podman rm -f mcp-envoy 2>/dev/null || true

podman run -d \
  --name mcp-envoy \
  --entrypoint="" \
  -p 8888:8888 \
  -v "${SCRIPT_DIR}/envoy.yaml:/etc/envoy/envoy.yaml:ro,z" \
  "${ENVOY_IMAGE}" \
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
  OAUTH_SCOPES_SUPPORTED="${OAUTH_SCOPES_SUPPORTED}" \
  "${SCRIPT_DIR}/bin/mcp-broker-router" \
  --mcp-broker-public-address="0.0.0.0:${BROKER_PORT}" \
  --mcp-gateway-config="${RUNTIME_CONFIG}" \
  --mcp-gateway-public-host="${MCP_PUBLIC_HOST}" \
  --mcp-gateway-private-host="${MCP_PRIVATE_HOST}" \
  --discovery-tools-enabled=false \
  --log-level="${LOG_LEVEL}"
