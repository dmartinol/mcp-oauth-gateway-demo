#!/usr/bin/env bash
# Apply JWT AuthPolicy when Kuadrant is installed; no-op otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=public-url.sh
source "${SCRIPT_DIR}/public-url.sh"

if ! kubectl get crd authpolicies.kuadrant.io >/dev/null 2>&1; then
  echo "==> Skipping AuthPolicy — Kuadrant CRDs not installed (run ./setup.sh first)" >&2
  exit 0
fi

SSO_ISSUER_URL="${SSO_ISSUER_URL:?SSO_ISSUER_URL is required — source ../env.prod or ../env.stage}"

echo "==> Applying AuthPolicy (issuer: ${SSO_ISSUER_URL})..." >&2
sed -e "s|https://sso.redhat.com/auth/realms/redhat-external|${SSO_ISSUER_URL}|" \
    -e "s|__MCP_PRM_URL__|${MCP_PRM_URL}|g" \
  "${SCRIPT_DIR}/manifests/authpolicy.yaml" | kubectl apply -f -
