#!/usr/bin/env bash
# Refreshes the broker token used by MCP Gateway to authenticate with insights-mcp.
# Run this when tools/list stops working (~5 min after the last token was issued).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MCP_AUTH_BASE="${MCP_AUTH_BASE:-https://mcp-auth.api.redhat.com}"
CALLBACK_PORT="${CALLBACK_PORT:-9090}"

echo "Obtaining fresh token..." >&2
TOKEN=$(python3 "${SCRIPT_DIR}/../local-deployment/get-token.py" \
  --mcp-auth-base "${MCP_AUTH_BASE}" \
  --callback-port "${CALLBACK_PORT}")

kubectl create secret generic insights-mcp-token \
  --from-literal=token="${TOKEN}" \
  --namespace mcp-system \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Token updated. Restarting broker to reload credentials..." >&2
kubectl rollout restart deployment/mcp-gateway -n mcp-system
kubectl rollout status deployment/mcp-gateway -n mcp-system --timeout=60s

echo "Done." >&2
