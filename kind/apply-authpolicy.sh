#!/usr/bin/env bash
# Apply JWT AuthPolicy when Kuadrant is installed; no-op otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MCP_PUBLIC_HOST="${MCP_PUBLIC_HOST:-localhost}"
MCP_PUBLIC_PORT="${MCP_PUBLIC_PORT:-8001}"

if ! kubectl get crd authpolicies.kuadrant.io >/dev/null 2>&1; then
  echo "==> Skipping AuthPolicy — Kuadrant CRDs not installed (run ./setup.sh first)" >&2
  exit 0
fi

SSO_ISSUER_URL="${SSO_ISSUER_URL:?SSO_ISSUER_URL is required — source ../env.prod or ../env.stage}"

echo "==> Applying AuthPolicy (issuer: ${SSO_ISSUER_URL})..." >&2
sed -e "s|https://sso.redhat.com/auth/realms/redhat-external|${SSO_ISSUER_URL}|" \
    -e "s|__MCP_PUBLIC_HOST__|${MCP_PUBLIC_HOST}|g" \
    -e "s|__MCP_PUBLIC_PORT__|${MCP_PUBLIC_PORT}|g" \
  "${SCRIPT_DIR}/manifests/authpolicy.yaml" | kubectl apply -f -
