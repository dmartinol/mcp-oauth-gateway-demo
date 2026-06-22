#!/usr/bin/env bash
# Stops Envoy (Podman) and mcp-broker-router started by start.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROKER_BIN="${SCRIPT_DIR}/bin/mcp-broker-router"

echo "==> Stopping Envoy container..." >&2
if podman container exists mcp-envoy 2>/dev/null; then
  podman stop mcp-envoy >/dev/null
  podman rm mcp-envoy >/dev/null
  echo "    mcp-envoy stopped." >&2
else
  echo "    mcp-envoy not running, skipping." >&2
fi

echo "==> Stopping mcp-broker-router..." >&2
if pgrep -f "${BROKER_BIN}" >/dev/null 2>&1; then
  pkill -f "${BROKER_BIN}"
  echo "    mcp-broker-router stopped." >&2
else
  echo "    mcp-broker-router not running, skipping." >&2
fi

echo "Done. Run ./start.sh to start again." >&2
