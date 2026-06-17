#!/usr/bin/env bash
# Obtains a fresh token and writes the Cursor MCP config snippet.
# Run this before starting Cursor (tokens expire; rerun when needed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_AUTH_BASE="${MCP_AUTH_BASE:-https://mcp-auth.stage.api.redhat.com}"
MCP_URL="${MCP_URL:-http://localhost:8888/mcp}"
CURSOR_CONFIG="${HOME}/.cursor/mcp.json"

if [ -n "${MCP_ACCESS_TOKEN:-}" ]; then
  TOKEN="${MCP_ACCESS_TOKEN}"
else
  echo "Obtaining token..." >&2
  TOKEN=$(MCP_AUTH_BASE="${MCP_AUTH_BASE}" "${SCRIPT_DIR}/get-token.sh")
fi

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
import json, re, sys

def strip_json_comments(text):
    """Remove // line comments (JSONC-style) before parsing."""
    lines = []
    for line in text.splitlines():
        in_string = escape = False
        out = []
        i = 0
        while i < len(line):
            c = line[i]
            if escape:
                out.append(c)
                escape = False
            elif c == "\\" and in_string:
                escape = True
                out.append(c)
            elif c == '"':
                in_string = not in_string
                out.append(c)
            elif not in_string and c == "/" and i + 1 < len(line) and line[i + 1] == "/":
                break
            else:
                out.append(c)
            i += 1
        lines.append("".join(out))
    return "\n".join(lines)

path, token, url = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    config = json.loads(strip_json_comments(f.read()))
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
