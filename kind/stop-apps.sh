#!/usr/bin/env bash
# Removes insights-mcp application workloads while leaving cluster infrastructure
# (Kind, Istio, MCP Gateway, Kuadrant, AuthPolicy) running.
#
# Run start-apps.sh to bring insights-mcp back without re-provisioning infra.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Delete MCPServerRegistration first so the broker stops polling the
# (soon-gone) upstream before the Helm release is removed.
echo "==> Removing MCPServerRegistration..." >&2
kubectl delete mcpserverregistrations.mcp.kuadrant.io/insights-mcp \
  -n mcp-system 2>/dev/null || true

echo "==> Uninstalling insights-mcp..." >&2
helm uninstall insights-mcp -n mcp-system 2>/dev/null || \
  echo "    insights-mcp not installed, skipping." >&2

echo "Done. Infrastructure (gateway, auth, kuadrant) is still running." >&2
echo "Run ./start-apps.sh to redeploy." >&2
