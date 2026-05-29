#!/usr/bin/env bash
# Obtains a fresh token and writes the Cursor MCP config snippet.
# Run this before starting Cursor (tokens expire; rerun when needed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_AUTH_BASE="${MCP_AUTH_BASE:-https://mcp-auth.api.redhat.com}"
MCP_URL="${MCP_URL:-http://localhost:8888/mcp}"
CURSOR_CONFIG="${HOME}/.cursor/mcp.json"

echo "Obtaining token..." >&2
TOKEN=$(MCP_AUTH_BASE="${MCP_AUTH_BASE}" "${SCRIPT_DIR}/get-token.sh")

# Build the mcp.json entry
ENTRY=$(cat <<EOF
{
  "mcpServers": {
    "mcp-gateway": {
      "url": "${MCP_URL}",
      "headers": {
        "Authorization": "Bearer ${TOKEN}"
      }
    }
  }
}
EOF
)

# Write or merge into ~/.cursor/mcp.json
mkdir -p "$(dirname "${CURSOR_CONFIG}")"
if [ ! -f "${CURSOR_CONFIG}" ]; then
  echo "${ENTRY}" > "${CURSOR_CONFIG}"
else
  # Merge: replace the mcp-gateway entry if it exists, otherwise add it.
  # Requires python3 (already needed for get-token.py).
  python3 - "${CURSOR_CONFIG}" "${TOKEN}" "${MCP_URL}" <<'PYEOF'
import json, sys

path, token, url = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    config = json.load(f)
config.setdefault("mcpServers", {})["mcp-gateway"] = {
    "url": url,
    "headers": {"Authorization": f"Bearer {token}"}
}
with open(path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
fi

echo "Written to ${CURSOR_CONFIG}" >&2
echo "Restart Cursor (or reload MCP servers) to pick up the new token." >&2
