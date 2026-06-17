#!/usr/bin/env bash
# Deploys insights-mcp application workloads onto an already-running cluster.
#
# Run this script to:
#   - Deploy or redeploy the insights-mcp server (Helm)
#   - Refresh the broker authentication token (opens a browser for RH SSO login)
#   - Register insights-mcp with the MCP Gateway broker
#
# Prerequisites: setup.sh must have been run at least once (cluster + infra in place).
# To stop without tearing down infra: stop-apps.sh
#
# Env vars (all optional):
#   INSIGHTS_MCP_VALUES   Extra Helm flags, e.g. "-f my-values.yaml" or "--set image.tag=dev"
#   MCP_AUTH_BASE         Auth adapter base URL (default: https://mcp-auth.stage.api.redhat.com)
#   CALLBACK_PORT         Local OAuth callback port (default: 9090)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MCP_AUTH_BASE="${MCP_AUTH_BASE:-https://mcp-auth.stage.api.redhat.com}"
CALLBACK_PORT="${CALLBACK_PORT:-9090}"

# ── insights-mcp Helm release ─────────────────────────────────────────────────
echo "==> Deploying insights-mcp..." >&2
helm upgrade -i insights-mcp "${SCRIPT_DIR}/charts/insights-mcp" \
  --namespace mcp-system \
  ${INSIGHTS_MCP_VALUES:-}

kubectl rollout status deployment/insights-mcp -n mcp-system --timeout=120s

# Apply the HTTPRoute that tells the mcps listener how to reach insights-mcp.
kubectl apply -f "${SCRIPT_DIR}/manifests/insights-mcp-httproute.yaml"

# ── Broker credential ─────────────────────────────────────────────────────────
# The broker uses this token to list tools from insights-mcp during registration.
# It is NOT injected into client tool/call requests — clients authenticate
# separately via AuthPolicy.
echo "==> Obtaining broker token for insights-mcp..." >&2
echo "    (A browser window will open for Red Hat SSO login)" >&2
TOKEN=$(python3 "${SCRIPT_DIR}/../local-deployment/get-token.py" \
  --mcp-auth-base "${MCP_AUTH_BASE}" \
  --callback-port "${CALLBACK_PORT}")

kubectl create secret generic insights-mcp-token \
  --from-literal=token="${TOKEN}" \
  --namespace mcp-system \
  --dry-run=client -o yaml | kubectl apply -f -

# The controller only accepts credential secrets that carry this label.
kubectl label secret insights-mcp-token -n mcp-system \
  mcp.kuadrant.io/secret=true --overwrite

# ── MCPServerRegistration ─────────────────────────────────────────────────────
# Creating (or re-applying) this resource tells the controller to federate
# insights-mcp tools into the broker. stop-apps.sh deletes it to deregister;
# this script re-applies it to re-enable.
echo "==> Registering insights-mcp with the broker..." >&2
kubectl apply -f "${SCRIPT_DIR}/manifests/mcpserverregistration.yaml"

kubectl wait --for=condition=Ready \
  mcpserverregistrations.mcp.kuadrant.io/insights-mcp \
  -n mcp-system --timeout=120s

echo "Done." >&2
