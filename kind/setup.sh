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
#   MCP_GATEWAY_VERSION   Helm chart version (default: 0.6.1)
#   MCP_PUBLIC_HOST       Hostname Cursor connects to (default: mcp.127-0-0-1.sslip.io)
#   MCP_PUBLIC_PORT       NodePort mapped on the host (default: 8001)
#   MCP_AUTH_BASE         Auth adapter base URL (default: https://mcp-auth.api.redhat.com)
#   CLUSTER_NAME          Kind cluster name (default: kind)
#   CALLBACK_PORT         Local OAuth callback port (default: 9090)
#   INSIGHTS_MCP_VALUES   Extra Helm flags passed through to start-apps.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MCP_GATEWAY_VERSION="${MCP_GATEWAY_VERSION:-0.6.1}"
MCP_PUBLIC_HOST="${MCP_PUBLIC_HOST:-mcp.127-0-0-1.sslip.io}"
MCP_PUBLIC_PORT="${MCP_PUBLIC_PORT:-8001}"
MCP_AUTH_BASE="${MCP_AUTH_BASE:-https://mcp-auth.api.redhat.com}"
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
echo "==> Installing Gateway API CRDs..." >&2
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml

# ── Step 3: Istio ─────────────────────────────────────────────────────────────
echo "==> Installing Istio..." >&2
helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
helm repo update istio

helm upgrade -i istio-base istio/base \
  -n istio-system --create-namespace --wait

helm upgrade -i istiod istio/istiod \
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
kubectl wait --for=condition=Ready mcpgatewayextension/mcp-gateway \
  -n mcp-system --timeout=120s

# ── Step 5: OAuth Protected Resource metadata ──────────────────────────────────
# The released chart (0.6.x) doesn't support oauthProtectedResource in the CRD
# yet — that field is in the local repo only. Instead, inject OAUTH_* env vars
# directly onto the broker deployment; the broker reads them to populate the
# /.well-known/oauth-protected-resource response. The controller uses strategic
# merge when reconciling the deployment, so unknown env vars survive restarts.
echo "==> Configuring OAuth Protected Resource metadata..." >&2
kubectl set env deployment/mcp-gateway -n mcp-system \
  OAUTH_RESOURCE_NAME="Red Hat MCP Gateway" \
  OAUTH_RESOURCE="http://${MCP_PUBLIC_HOST}:${MCP_PUBLIC_PORT}/mcp" \
  OAUTH_AUTHORIZATION_SERVERS="${MCP_AUTH_BASE}" \
  OAUTH_BEARER_METHODS_SUPPORTED="header" \
  OAUTH_SCOPES_SUPPORTED="openid,offline_access"

# Expose /.well-known/ through the public listener. The controller-owned route
# only covers /mcp, so a separate HTTPRoute is needed and won't be overwritten.
kubectl apply -f "${SCRIPT_DIR}/manifests/oauth-metadata-httproute.yaml"

kubectl rollout status deployment/mcp-gateway -n mcp-system --timeout=60s

# ── Step 6: Kuadrant (AuthPolicy enforcement) ──────────────────────────────────
echo "==> Installing Kuadrant operator..." >&2
helm repo add kuadrant https://kuadrant.io/helm-charts 2>/dev/null || true
helm repo update kuadrant

helm upgrade -i kuadrant-operator kuadrant/kuadrant-operator \
  --namespace kuadrant-system \
  --create-namespace \
  --wait \
  --timeout=600s

echo "==> Applying Kuadrant CR..." >&2
kubectl apply -n kuadrant-system \
  -f https://raw.githubusercontent.com/Kuadrant/mcp-gateway/main/config/kuadrant/kuadrant.yaml

echo "==> Waiting for Kuadrant CR to be ready..." >&2
kubectl wait --for=condition=Ready kuadrant/kuadrant \
  -n kuadrant-system --timeout=300s

echo "==> Waiting for Authorino deployment..." >&2
kubectl wait --for=condition=available deployment/authorino \
  -n kuadrant-system --timeout=120s

# ── Step 7: AuthPolicy ─────────────────────────────────────────────────────────
# Enforces JWT validation at the Istio Gateway layer and emits the
# WWW-Authenticate header that triggers Cursor's automatic OAuth flow.
echo "==> Applying AuthPolicy..." >&2
kubectl apply -f "${SCRIPT_DIR}/manifests/authpolicy.yaml"

# ── Steps 8-10: Deploy application workloads ──────────────────────────────────
# Delegated to start-apps.sh so that infra and app lifecycles stay independent.
# MCP_AUTH_BASE and CALLBACK_PORT are already set above and inherited by the subshell.
export MCP_AUTH_BASE CALLBACK_PORT
"${SCRIPT_DIR}/start-apps.sh"

# ── Summary ────────────────────────────────────────────────────────────────────
echo "" >&2
echo "Setup complete." >&2
echo "" >&2
echo "  Gateway:   http://${MCP_PUBLIC_HOST}:${MCP_PUBLIC_PORT}/mcp" >&2
echo "  Discovery: http://${MCP_PUBLIC_HOST}:${MCP_PUBLIC_PORT}/.well-known/oauth-protected-resource" >&2
echo "" >&2
echo "Configure Cursor:" >&2
echo '  {"mcpServers":{"mcp-gateway":{"url":"http://'"${MCP_PUBLIC_HOST}"':'"${MCP_PUBLIC_PORT}"'/mcp"}}}' >&2
echo "" >&2
echo "Cursor will discover the authorization server automatically and prompt for login." >&2
echo "When the broker token expires (~5 min), run: ./refresh-token.sh" >&2
