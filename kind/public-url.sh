#!/usr/bin/env bash
# Resolve the public MCP endpoint. Source from other kind scripts.
#
#   MCP_PUBLIC_URL   optional — full URL, e.g. https://xyz.ngrok-free.app/mcp
#   MCP_PUBLIC_HOST / MCP_PUBLIC_PORT — fallback → http://host:port/mcp
#
# Exports: MCP_RESOURCE_URL, MCP_PRM_URL, MCP_PUBLIC_HOST (gateway listener hostname)
set -euo pipefail

eval "$(python3 - <<'PY'
import json, os, shlex
from urllib.parse import urlparse, urlunparse

host = os.environ.get("MCP_PUBLIC_HOST", "localhost")
port = os.environ.get("MCP_PUBLIC_PORT", "8001")
url = os.environ.get("MCP_PUBLIC_URL", "").strip()

if url:
    p = urlparse(url)
    path = p.path or "/mcp"
    if not path.endswith("/mcp"):
        path = path.rstrip("/") + "/mcp"
    resource = urlunparse((p.scheme, p.netloc, path, "", "", ""))
    prm = urlunparse((p.scheme, p.netloc, "/.well-known/oauth-protected-resource", "", "", ""))
    gateway_host = p.hostname or host
else:
    resource = f"http://{host}:{port}/mcp"
    prm = f"http://{host}:{port}/.well-known/oauth-protected-resource"
    gateway_host = host

for name, value in (
    ("MCP_RESOURCE_URL", resource),
    ("MCP_PRM_URL", prm),
    ("MCP_PUBLIC_HOST", gateway_host),
):
    print(f"export {name}={shlex.quote(value)}")
PY
)"
