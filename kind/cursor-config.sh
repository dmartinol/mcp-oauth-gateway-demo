#!/usr/bin/env bash
# Cursor Bearer workaround for the Kind gateway (:8001 or MCP_PUBLIC_URL).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=public-url.sh
source "${SCRIPT_DIR}/public-url.sh"

exec env MCP_URL="${MCP_RESOURCE_URL}" \
  "${SCRIPT_DIR}/../local-deployment/cursor-config.sh" "$@"
