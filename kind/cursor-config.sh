#!/usr/bin/env bash
# Cursor Bearer workaround for the Kind gateway (:8001).
# Pins MCP_URL so kind MCP_PUBLIC_HOST (hostname only) is not confused with local-deployment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MCP_PUBLIC_HOST="${MCP_PUBLIC_HOST:-localhost}"
MCP_PUBLIC_PORT="${MCP_PUBLIC_PORT:-8001}"

exec env MCP_URL="http://${MCP_PUBLIC_HOST}:${MCP_PUBLIC_PORT}/mcp" \
  "${SCRIPT_DIR}/../local-deployment/cursor-config.sh" "$@"
