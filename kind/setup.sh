#!/usr/bin/env bash
# Provisions a Kind cluster with MCP Gateway, Istio, and Kuadrant AuthPolicy,
# then deploys insights-mcp by delegating to start-apps.sh.
#
# Run once to stand up the full environment. After that:
#   stop-apps.sh    — remove insights-mcp, leave infra running
#   start-apps.sh   — redeploy insights-mcp (and refresh the broker token)
#   refresh-token.sh — refresh only the broker token without redeploying
#   teardown.sh     — remove everything including the Kind cluster
#
# Env vars (all optional):
#   MCP_GATEWAY_VERSION   Helm chart version (default: 0.7.0)
#   MCP_GATEWAY_GIT_REF   mcp-gateway git ref for Kuadrant CR manifest (default: v${MCP_GATEWAY_VERSION})
#   MCP_GATEWAY_EXTENSION_NAME  MCPGatewayExtension resource name (default: mcp-gateway-extension; was mcp-gateway in chart <0.7)
#   GATEWAY_API_VERSION   Gateway API CRDs release tag (default: v1.5.1)
#   ISTIO_VERSION         Istio Helm chart version for istio/base and istiod (default: 1.30.1)
#   KUADRANT_OPERATOR_VERSION  Kuadrant operator Helm chart version (default: 1.4.2)
#   MCP_PUBLIC_HOST       Hostname Cursor connects to (default: localhost)
#   MCP_PUBLIC_PORT       NodePort mapped on the host (default: 8001)
#   MCP_PUBLIC_URL        Full MCP URL — overrides host/port, e.g. https://xyz.ngrok-free.app/mcp
#   MCP_AUTH_BASE         Auth adapter base URL (default: https://mcp-auth.stage.api.redhat.com)
#   SSO_ISSUER_URL        SSO JWT issuer for AuthPolicy (default: https://sso.stage.redhat.com/auth/realms/redhat-external)
#   OAUTH_SCOPES          Scopes for broker token request (source env.stage or env.prod)
#   OAUTH_SCOPES_SUPPORTED  Comma-separated scopes advertised in Protected Resource Metadata / PRM (source env.stage or env.prod)
#   CLUSTER_NAME          Kind cluster name (default: kind)
#   CALLBACK_PORT         Local OAuth callback port (default: 9090)
#   INSIGHTS_MCP_VALUES   Extra Helm flags passed through to start-apps.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MCP_GATEWAY_VERSION="${MCP_GATEWAY_VERSION:-0.7.0}"
MCP_GATEWAY_GIT_REF="${MCP_GATEWAY_GIT_REF:-v${MCP_GATEWAY_VERSION}}"
MCP_GATEWAY_EXTENSION_NAME="${MCP_GATEWAY_EXTENSION_NAME:-mcp-gateway-extension}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"
ISTIO_VERSION="${ISTIO_VERSION:-1.30.1}"
KUADRANT_OPERATOR_VERSION="${KUADRANT_OPERATOR_VERSION:-1.4.2}"
# Use localhost — not sslip.io. Chromium/Electron may HTTPS-upgrade public-looking
# hostnames and fail with ERR_SSL_CLIENT_AUTH_CERT_NEEDED before OAuth can start.
MCP_PUBLIC_HOST="${MCP_PUBLIC_HOST:-localhost}"
MCP_PUBLIC_PORT="${MCP_PUBLIC_PORT:-8001}"
# shellcheck source=public-url.sh
source "${SCRIPT_DIR}/public-url.sh"
MCP_AUTH_BASE="${MCP_AUTH_BASE:-https://mcp-auth.stage.api.redhat.com}"
SSO_ISSUER_URL="${SSO_ISSUER_URL:-https://sso.stage.redhat.com/auth/realms/redhat-external}"
OAUTH_SCOPES_SUPPORTED="${OAUTH_SCOPES_SUPPORTED:-api.console,api.ocm,openid,offline_access}"
CLUSTER_NAME="${CLUSTER_NAME:-kind}"
CALLBACK_PORT="${CALLBACK_PORT:-9090}"
export KIND_EXPERIMENTAL_PROVIDER=podman

# ── Step 1: Kind cluster ───────────────────────────────────────────────────────
echo "==> Creating Kind cluster '${CLUSTER_NAME}'..." >&2
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "    Cluster already exists, skipping." >&2
else
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/cluster.yaml"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"

# ── Step 2: Gateway API CRDs ───────────────────────────────────────────────────
echo "==> Installing Gateway API CRDs (${GATEWAY_API_VERSION})..." >&2
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# ── Step 3: Istio ─────────────────────────────────────────────────────────────
echo "==> Installing Istio (${ISTIO_VERSION})..." >&2
helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
helm repo update istio

helm upgrade -i istio-base istio/base \
  --version "${ISTIO_VERSION}" \
  -n istio-system --create-namespace --wait

helm upgrade -i istiod istio/istiod \
  --version "${ISTIO_VERSION}" \
  -n istio-system --wait

# ── Step 4: MCP Gateway ────────────────────────────────────────────────────────
# The Helm chart installs its own CRDs (mcp.kuadrant.io group). Do not apply
# local repo CRDs here — the chart manages them and re-applying can cause
# resource version conflicts.
echo "==> Installing MCP Gateway ${MCP_GATEWAY_VERSION}..." >&2
kubectl create namespace gateway-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade -i mcp-gateway oci://ghcr.io/kuadrant/charts/mcp-gateway \
  --version "${MCP_GATEWAY_VERSION}" \
  --namespace mcp-system \
  --create-namespace \
  --set gateway.create=true \
  --set "gateway.publicHost=${MCP_PUBLIC_HOST}" \
  --set gateway.nodePort.create=true \
  --set gateway.nodePort.mcpPort=30471 \
  --set mcpGatewayExtension.create=true \
  --wait

echo "==> Waiting for MCPGatewayExtension to become ready..." >&2
kubectl wait --for=condition=Ready "mcpgatewayextension/${MCP_GATEWAY_EXTENSION_NAME}" \
  -n mcp-system --timeout=120s

# ── Step 5: OAuth Protected Resource metadata ──────────────────────────────────
# Chart 0.7.0+ reconciles the broker deployment from MCPGatewayExtension; patch
# spec.oauthProtectedResource so the controller injects OAUTH_* env vars.
"${SCRIPT_DIR}/configure-oauth-metadata.sh"

# ── Step 6: Kuadrant (AuthPolicy enforcement) ──────────────────────────────────
echo "==> Installing Kuadrant operator (${KUADRANT_OPERATOR_VERSION})..." >&2
helm repo add kuadrant https://kuadrant.io/helm-charts 2>/dev/null || true
helm repo update kuadrant

helm upgrade -i kuadrant-operator kuadrant/kuadrant-operator \
  --version "${KUADRANT_OPERATOR_VERSION}" \
  --namespace kuadrant-system \
  --create-namespace \
  --wait \
  --timeout=600s

echo "==> Applying Kuadrant CR (${MCP_GATEWAY_GIT_REF})..." >&2
kubectl apply -n kuadrant-system \
  -f "https://raw.githubusercontent.com/Kuadrant/mcp-gateway/${MCP_GATEWAY_GIT_REF}/config/kuadrant/kuadrant.yaml"

echo "==> Waiting for Kuadrant CR to be ready..." >&2
kubectl wait --for=condition=Ready kuadrant/kuadrant \
  -n kuadrant-system --timeout=300s

echo "==> Waiting for Authorino deployment..." >&2
kubectl wait --for=condition=available deployment/authorino \
  -n kuadrant-system --timeout=120s

# ── Step 7: AuthPolicy ─────────────────────────────────────────────────────────
# Enforces JWT validation at the Istio Gateway layer and emits the
# WWW-Authenticate header that triggers Cursor's automatic OAuth flow.
"${SCRIPT_DIR}/apply-authpolicy.sh"

sed -e "s|__MCP_PUBLIC_HOST__|${MCP_PUBLIC_HOST}|g" \
  "${SCRIPT_DIR}/manifests/oauth-metadata-httproute.yaml" | kubectl apply -f -

# ── Steps 8-10: Deploy application workloads ──────────────────────────────────
# Delegated to start-apps.sh so that infra and app lifecycles stay independent.
# MCP_AUTH_BASE and CALLBACK_PORT are already set above and inherited by the subshell.
export MCP_AUTH_BASE CALLBACK_PORT
"${SCRIPT_DIR}/start-apps.sh"

# ── Summary ────────────────────────────────────────────────────────────────────
echo "" >&2
echo "Setup complete." >&2
echo "" >&2
echo "  Gateway:   ${MCP_RESOURCE_URL}" >&2
echo "  Discovery: ${MCP_PRM_URL}" >&2
echo "" >&2
echo "Configure Cursor:" >&2
echo '  {"mcpServers":{"mcp-gateway":{"url":"'"${MCP_RESOURCE_URL}"'"}}}' >&2
echo "" >&2
echo "Cursor will discover the authorization server automatically and prompt for login." >&2
echo "When the broker token expires (~5 min), run: ./refresh-token.sh" >&2
