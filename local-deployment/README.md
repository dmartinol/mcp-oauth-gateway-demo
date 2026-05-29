# Local Deployment: MCP OAuth Gateway (with insights-mcp as example backend)

This guide sets up MCP Gateway locally using the standalone binary with Podman-hosted Envoy,
demonstrating the OAuth authorization flow via the [MCP Auth Proxy](https://gitlab.cee.redhat.com/lightforge/mcp-auth-proxy)
(`https://mcp-auth.api.redhat.com`) and Red Hat SSO.

`insights-mcp` is the example backend. Additional MCP servers can be registered by adding entries
to `config.yaml` and corresponding clusters + virtual hosts to `envoy.yaml`.

## Overview

```
MCP Client (Cursor)
    │
    ▼ :8888
 Envoy (podman)
    │  ext_proc ──► Router (host :50051)
    │
    ├──► Broker (host :8081) ──► insights-mcp (host :8080/mcp)
    │
    └──► insights-mcp (host :8080/mcp)   ← direct tools/call routing
```

**Components:**

| Component | Address | Role |
|---|---|---|
| mcp-broker-router (broker) | host:8081 | Aggregates tools, serves MCP protocol |
| mcp-broker-router (router) | host:50051 | gRPC ext_proc — parses requests, sets routing headers |
| Envoy | host:8888 | Listens for MCP clients, calls ext_proc, routes traffic |
| insights-mcp | host:8080 | Upstream MCP server (must be running separately) |

## Prerequisites

- Go 1.25+
- Python 3 (for the OAuth login flow)
- Podman 4.1+
- The `insights-mcp` server already running on `http://127.0.0.1:8080/mcp`
- The mcp-gateway source checked out

## Step 1: Set required environment variables

```bash
# Stable JWT signing key — generate once and persist across restarts.
# Changing it invalidates all active sessions.
export GATEWAY_SIGNING_KEY=$(openssl rand -hex 32)

# MCP Auth Adapter — authorization server for the MCP ecosystem.
# Implements DCR and proxies to Red Hat SSO.
export MCP_AUTH_BASE=https://mcp-auth.api.redhat.com

# Persist to .env for subsequent sessions
echo "export GATEWAY_SIGNING_KEY=${GATEWAY_SIGNING_KEY}" > .env
echo "export MCP_AUTH_BASE=${MCP_AUTH_BASE}" >> .env
```

## Step 2: Configure Cursor with a fresh token

Run this before starting Cursor (and again when the token expires):

```bash
./cursor-config.sh
```

This will:
1. Register a client via DCR at `https://mcp-auth.api.redhat.com/register`
2. Open your browser for Red Hat SSO login
3. Capture the authorization code via a local callback server on `:9090`
4. Write the token into `~/.cursor/mcp.json` under the `mcp-gateway` entry

After it completes, restart Cursor or reload MCP servers (**Settings → MCP → Refresh**).

> **Token expiry:** RH SSO access tokens expire in ~5 minutes. Rerun `./cursor-config.sh`
> and reload Cursor when tools stop working.

## Step 3: Start the gateway

```bash
source .env
./start.sh
```

`start.sh` will:
1. Obtain a broker access token via the same OAuth flow (browser login)
2. Write `config.runtime.yaml` with the token substituted in
3. Build the `mcp-broker-router` binary from source
4. Start an Envoy container (Podman) on `:8888`
5. Start the broker-router on `:8081` (router on `:50051`)

## Step 4: Verify

```bash
# Health check (direct to broker)
curl http://localhost:8081/healthz

# Check authorization server advertisement
curl -sS http://localhost:8888/.well-known/oauth-protected-resource | jq .
# Expected: authorization_servers contains https://mcp-auth.api.redhat.com

# List aggregated tools through Envoy (requires a valid token)
TOKEN=$(./get-token.sh)
curl -sS -X POST http://localhost:8888/mcp \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools[].name'
```

Expected: tools prefixed with `insights_` from the insights-mcp server.

## Scripts

| Script | Purpose |
|---|---|
| `start.sh` | Builds binary, starts Envoy + broker-router |
| `get-token.sh` | Gets an access token via MCP Auth Adapter (OAuth2 + PKCE) |
| `cursor-config.sh` | Gets a token and writes it into `~/.cursor/mcp.json` |

### Environment variables

| Variable | Default | Required | Purpose |
|---|---|---|---|
| `GATEWAY_SIGNING_KEY` | — | Yes | JWT session signing key (≥32 bytes) |
| `MCP_AUTH_BASE` | `https://mcp-auth.api.redhat.com` | No | MCP Auth Adapter base URL |
| `BROKER_PORT` | `8081` | No | Broker HTTP port (must not conflict with insights-mcp) |
| `MCP_PUBLIC_HOST` | `localhost:8888` | No | Hostname:port Envoy listens on |
| `LOG_LEVEL` | `0` | No | `-4`=debug, `0`=info, `4`=warn, `8`=error |
| `CALLBACK_PORT` | `9090` | No | Local port for OAuth browser callback |

## Configuration files

### `config.yaml` — MCP server registry

```yaml
servers:
  - name: insights-mcp
    url: http://127.0.0.1:8080/mcp   # broker connects here for tool listing
    hostname: insights-mcp.mcp.local  # virtual hostname used for Envoy routing
    prefix: "insights_"              # prepended to all tool names
    state: Enabled
    auth:
      type: bearer
      token: "INSIGHTS_MCP_TOKEN_PLACEHOLDER"  # replaced at runtime by start.sh
```

`start.sh` substitutes the real token into `config.runtime.yaml` (gitignored) on every start.

**Key fields:**

| Field | Purpose |
|---|---|
| `url` | Where the broker connects to fetch tools. Use `127.0.0.1` (not `localhost`) to force IPv4 on macOS. |
| `hostname` | Virtual hostname the router injects as `:authority` to steer `tools/call` to the right Envoy cluster. Must match an Envoy `domains` entry. |
| `prefix` | Prepended to every tool name to avoid collisions when aggregating multiple servers. |
| `auth.token` | Bearer token the broker uses for its own connection to the backend (for tool listing). |

**Adding another MCP server:** append a new entry under `servers:` with a distinct `name`, `hostname`, and `prefix`, then add a matching cluster and virtual host to `envoy.yaml`. Run `start.sh` to apply.

### `envoy.yaml` — Envoy proxy

Three clusters are defined:

| Cluster | Host | Port | Purpose |
|---|---|---|---|
| `mcp_broker` | `host.containers.internal` | `8081` | Default route — all MCP protocol traffic |
| `mcp_router` | `host.containers.internal` | `50051` | ext_proc gRPC — router intercepts every request |
| `insights_mcp_upstream` | `host.containers.internal` | `8080` | Direct route for `tools/call` — bypasses broker |

The virtual host `insights-mcp.mcp.local` in `envoy.yaml` matches the `hostname` in `config.yaml`.
When a client calls a tool, the router rewrites `:authority` to this value and Envoy routes
the request directly to the upstream MCP server with the client's `Authorization` header intact.

## Authentication flow

The gateway advertises the MCP Auth Adapter as its authorization server via
`/.well-known/oauth-protected-resource`. MCP clients that follow the
[MCP authorization spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
discover this automatically.

```
Cursor → GET /.well-known/oauth-protected-resource
       ← authorization_servers: ["https://mcp-auth.api.redhat.com"]

Cursor → GET https://mcp-auth.api.redhat.com/.well-known/openid-configuration
       ← registration_endpoint, authorization_endpoint, token_endpoint

Cursor → POST https://mcp-auth.api.redhat.com/register  (DCR)
       ← client_id: "mcp-client"

Cursor → Authorization Code + PKCE flow → RH SSO login → access token

Cursor → POST http://localhost:8888/mcp
         Authorization: Bearer <token>
       ← MCP response (token forwarded to insights-mcp)
```

In standalone mode the gateway does not enforce authentication itself — it passes the
`Authorization` header through to insights-mcp which validates it. Use `./cursor-config.sh`
to inject a valid token into Cursor until automatic token acquisition is supported.

## Troubleshooting

### `GATEWAY_SIGNING_KEY must be set`

```bash
export GATEWAY_SIGNING_KEY=$(openssl rand -hex 32)
```

### Browser does not open for login

The script falls back to printing the URL. Copy it manually into your browser.
To use a different callback port: `CALLBACK_PORT=9091 ./cursor-config.sh`.

### Envoy cannot reach broker or insights-mcp

Podman automatically injects `host.containers.internal` into the container's `/etc/hosts`.
Verify:

```bash
podman exec mcp-envoy cat /etc/hosts | grep host.containers.internal
podman exec mcp-envoy curl -sf http://host.containers.internal:8081/healthz
```

If the hostname is missing, confirm you are using Podman 4.1+: `podman --version`.

### `tools/list` returns empty

1. Check broker status:
   ```bash
   curl http://localhost:8081/status
   ```
2. Verify insights-mcp is running and reachable:
   ```bash
   curl -sS -X POST http://127.0.0.1:8080/mcp \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
   ```
3. Check broker-router logs for authentication errors to insights-mcp — the broker token
   may have expired. Restart `start.sh` to obtain a fresh one.

### ext_proc gRPC errors in Envoy logs

```bash
podman logs mcp-envoy
```

The router (`:50051`) must be running before Envoy processes requests.
Envoy retries the gRPC connection automatically.

### Port conflicts

```bash
lsof -i :8080   # insights-mcp
lsof -i :8081   # broker
lsof -i :50051  # router
lsof -i :8888   # envoy
```

## Stopping

```bash
podman stop mcp-envoy && podman rm mcp-envoy
pkill -f mcp-broker-router
```

## Limitations of standalone mode

- No dynamic server discovery — server changes require editing `config.yaml` and restarting
- No built-in token enforcement — the gateway passes tokens through; insights-mcp validates them
- Access tokens expire (~5 min) — rerun `./cursor-config.sh` and reload Cursor
- No virtual server filtering (per-client tool subsets)
- Single instance — no HA without external load balancing and Redis session store

For full capabilities, see the [Kubernetes installation guide](https://github.com/Kuadrant/mcp-gateway/blob/main/docs/guides/how-to-install-and-configure.md).
