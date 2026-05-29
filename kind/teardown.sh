#!/usr/bin/env bash
# Removes everything created by setup.sh: application workloads, cluster
# infrastructure, and the Kind cluster itself.
#
# For a softer stop that keeps the cluster running, use stop-apps.sh instead.
#
# Env vars (all optional):
#   CLUSTER_NAME   Kind cluster name to delete (default: kind)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-kind}"
export KIND_EXPERIMENTAL_PROVIDER=podman

# ── Application workloads ──────────────────────────────────────────────────────
# Remove insights-mcp and its MCPServerRegistration before deleting the cluster
# so the broker has a chance to deregister cleanly.
"${SCRIPT_DIR}/stop-apps.sh"

# ── Kind cluster ───────────────────────────────────────────────────────────────
# Deleting the cluster removes all namespaces, Helm releases, CRDs, and the
# Podman container backing the node — nothing else needs explicit cleanup.
echo "==> Deleting Kind cluster '${CLUSTER_NAME}'..." >&2
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  kind delete cluster --name "${CLUSTER_NAME}"
else
  echo "    Cluster '${CLUSTER_NAME}' not found, skipping." >&2
fi

echo "Done. Run ./setup.sh to provision a fresh environment." >&2
