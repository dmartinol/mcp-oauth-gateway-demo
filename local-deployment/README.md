# Local Deployment: MCP OAuth Gateway (with insights-mcp as example backend)

This guide sets up MCP Gateway locally using the standalone binary with Podman-hosted Envoy,
demonstrating the OAuth authorization flow via the [MCP Auth Adapter](https://github.com/velias/mcp-auth-adapter)
and [Red Hat SSO](https://sso.redhat.com).

`insights-mcp` is the example backend. Additional MCP servers can be registered by adding entries
to `config.yaml` and corresponding clusters + virtual hosts to `envoy.yaml`.

## Overview

The local stack runs on your machine (Envoy + broker-router + insights-mcp). **OAuth does not** —
tokens come from the hosted [MCP Auth Adapter](../README.md#mcp-auth-adapter) (`MCP_AUTH_BASE`).
The broker advertises the adapter in PRM (`/.well-known/oauth-protected-resource`). In this demo,
`start.sh` also calls the adapter via `get-token.py` to obtain tokens for the broker and Cursor
before the client connects. See [Authentication flow](#authentication-flow) for the full sequence.

```
MCP Client (Cursor)
    │
    │  OAuth (DCR + PKCE) ──────────────────────────────┐
    │  Bearer token on MCP requests                      │
    ▼ :8888                                              ▼
 Envoy (podman)                              MCP Auth Adapter (hosted)
    │  ext_proc ──► Router (host :50051)         DCR /authorize /token
    │                                                    │
    ├──► Broker (host :8081) ──► insights-mcp           └──► Red Hat SSO
    │         (host :8080/mcp)
    │
    └──► insights-mcp (host :8080/mcp)   ← direct tools/call routing
```

**Components:**

| Component | Address | Role |
|---|---|---|
| [MCP Auth Adapter](https://github.com/velias/mcp-auth-adapter) | `MCP_AUTH_BASE` (external) | OAuth authorization server — see [root README](../README.md#mcp-auth-adapter) |
| mcp-broker-router (broker) | host:8081 | Aggregates tools, serves MCP protocol; advertises adapter in PRM |
| mcp-broker-router (router) | host:50051 | gRPC ext_proc — parses requests, sets routing headers |
| Envoy | host:8888 | Listens for MCP clients, calls ext_proc, routes traffic |
| insights-mcp | host:8080 | Upstream MCP server (must be running separately) |
| Red Hat SSO | `sso.stage.redhat.com` / `sso.redhat.com` | Identity provider behind the adapter (selected via `env.stage` / `env.prod`) |

## Prerequisites

- Go 1.25+
- Python 3 (for the OAuth login flow)
- Podman 4.1+
- The `insights-mcp` server already running on `http://127.0.0.1:8080/mcp`
- The [mcp-gateway](https://github.com/Kuadrant/mcp-gateway) source checked out

### Clone mcp-gateway

`start.sh` builds `mcp-broker-router` from source. Clone the gateway repo as a sibling
of this demo repo (or set `MCP_GATEWAY_ROOT` to your checkout path):

```bash
git clone https://github.com/Kuadrant/mcp-gateway.git ../mcp-gateway
cd ../mcp-gateway && git checkout "v${MCP_GATEWAY_VERSION:-0.7.0}"
```

> **Note:** `start.sh` previously assumed this demo lived inside the mcp-gateway tree.
> If you see `go.mod file not found`, the clone step above is required.

## Step 1: Set required environment variables

### SSO environment

Source an SSO environment file from the **repo root** to select which Red Hat SSO instance to use:

```bash
# Stage Insights API:
source ../env.stage

# Production Insights API:
source ../env.prod
```

Both files export `MCP_AUTH_BASE`, `OAUTH_SCOPES`, and `OAUTH_SCOPES_SUPPORTED`. If neither is sourced, scripts fall back
to their stage defaults.

See the [root README](../README.md#sso-environment-config-files) for the full status table.

### Kind gateway (optional — different stack)

For the **Kind** deployment on `:8001`, use [kind/README.md](../kind/README.md). Claude Code:

```bash
claude mcp add mcp-gateway --transport http http://localhost:8001/mcp --scope project
```

Cursor against Kind: run `./cursor-config.sh` from the `kind/` directory (pins `:8001`).
That is **not** the local Envoy stack below (`:8888`).

### GATEWAY_SIGNING_KEY

This is required by the broker-router. Generate it once and persist across restarts —
changing it invalidates all active sessions.

```bash
export GATEWAY_SIGNING_KEY=$(openssl rand -hex 32)

# Persist for subsequent sessions
echo "export GATEWAY_SIGNING_KEY=${GATEWAY_SIGNING_KEY}" > .env
```

## Step 2: Start the gateway

```bash
source ../env.stage      # or ../env.prod
source .env              # GATEWAY_SIGNING_KEY
./start.sh
```

`start.sh` will:
1. Obtain an access token via OAuth (browser login)
2. Write the token into `~/.cursor/mcp.json` under the `mcp-gateway` entry
3. Write `config.runtime.yaml` with the same token substituted in
4. Build the `mcp-broker-router` binary from source
5. Start an Envoy container (Podman) on `:8888`
6. Start the broker-router on `:8081` (router on `:50051`)

After it completes, restart Cursor or reload MCP servers (**Settings → MCP → Refresh**).

> **Cursor URL:** `start.sh` always writes `http://localhost:8888/mcp` into `~/.cursor/mcp.json`
> (via `MCP_LISTEN_ADDR`, ignoring kind's `MCP_PUBLIC_HOST` / stray `MCP_URL` in your shell).
> For Kind, use `kind/cursor-config.sh` instead.

> **Token expiry:** RH SSO access tokens expire in ~5 minutes. Rerun `./start.sh`
> (or just `./cursor-config.sh` if the gateway is already running) and reload Cursor
> when tools stop working.

To start the gateway without touching `~/.cursor/mcp.json`: `SKIP_CURSOR_CONFIG=1 ./start.sh`

## Step 3: Refresh Cursor token only (optional)

If the gateway is already running and you only need a new token in Cursor:

```bash
./cursor-config.sh
```

This runs the same OAuth flow and updates `~/.cursor/mcp.json` without restarting Envoy
or the broker.

## Step 4: Verify (optional)

```bash
# Health check (direct to broker)
curl http://localhost:8081/healthz

# Check authorization server advertisement
curl -sS http://localhost:8888/.well-known/oauth-protected-resource | jq .
# Expected: authorization_servers contains https://mcp-auth.stage.api.redhat.com

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
| `start.sh` | OAuth login, updates `~/.cursor/mcp.json`, builds binary, starts Envoy + broker-router |
| `stop.sh` | Stops Envoy container and mcp-broker-router |
| `get-token.sh` | Gets an access token via MCP Auth Adapter (OAuth2 + PKCE) |
| `cursor-config.sh` | Gets a token and writes it into `~/.cursor/mcp.json` (without restarting the gateway) |

### Environment variables

| Variable | Default | Required | Purpose |
|---|---|---|---|
| `GATEWAY_SIGNING_KEY` | — | Yes | JWT session signing key (≥32 bytes) |
| `MCP_GATEWAY_VERSION` | `0.7.0` | No | mcp-gateway git tag when building broker-router (`v${MCP_GATEWAY_VERSION}`) |
| `ENVOY_IMAGE` | `docker.io/envoyproxy/envoy:v1.33-latest` | No | Envoy container image for the local proxy |
| `MCP_AUTH_BASE` | `https://mcp-auth.stage.api.redhat.com` | No | MCP Auth Adapter base URL |
| `BROKER_PORT` | `8081` | No | Broker HTTP port (must not conflict with insights-mcp) |
| `MCP_LISTEN_ADDR` | `localhost:8888` | No | Host:port Envoy listens on (local-deployment only) |
| `LOG_LEVEL` | `0` | No | `-4`=debug, `0`=info, `4`=warn, `8`=error |
| `CALLBACK_PORT` | `9090` | No | Local port for OAuth browser callback |
| `SKIP_CURSOR_CONFIG` | `0` | No | Set to `1` to skip updating `~/.cursor/mcp.json` in `start.sh` |

## Broker credentials

The standalone `mcp-broker-router` needs the same kind of **broker credential** as the Kind
deployment: a bearer token the broker sends to `insights-mcp` when fetching tools for
**`tools/list`**. It is **not** injected into client `tools/call` requests — those use the
caller's `Authorization` header (forwarded by Envoy).

| | Broker credential | Client credential |
|---|---|---|
| **Used by** | `mcp-broker-router` (broker side) | MCP client (e.g. Cursor) |
| **Purpose** | Upstream `tools/list` | Client requests to the gateway and `tools/call` |
| **Stored in** | `config.runtime.yaml` → `servers[].auth.token` | `~/.cursor/mcp.json` (or client OAuth) |
| **Wired via** | `--mcp-gateway-config` | Manual Bearer header in this demo |

`config.yaml` holds a placeholder (`INSIGHTS_MCP_TOKEN_PLACEHOLDER`); `start.sh` substitutes the
real token after `get-token.py` runs. Unlike Kind, this demo **reuses the same OAuth token** for
both broker and Cursor — a convenience because standalone mode has no AuthPolicy enforcing
separate client auth.

The `auth.token` field is the file-based equivalent of Kuadrant's `credentialRef` on
`MCPServerRegistration`. See:

- [MCPServerRegistration CRD — `credentialRef`](https://docs.kuadrant.io/dev/mcp-gateway/docs/reference/mcpserverregistration/)
- [MCP Server Configuration](https://docs.kuadrant.io/dev/mcp-gateway/docs/guides/register-mcp-servers/)
- [Connecting to External MCP Servers](https://docs.kuadrant.io/dev/mcp-gateway/docs/guides/external-mcp-server/) (Secret + `credentialRef` pattern on Kubernetes)
- [MCP Gateway documentation](https://docs.kuadrant.io/mcp-gateway/)

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

The gateway advertises the [MCP Auth Adapter](../README.md#mcp-auth-adapter) as its authorization server via
`/.well-known/oauth-protected-resource`. MCP clients that follow the
[MCP authorization spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
discover this automatically.

```
Cursor → GET /.well-known/oauth-protected-resource
       ← authorization_servers: ["https://mcp-auth.stage.api.redhat.com"]

Cursor → GET https://mcp-auth.stage.api.redhat.com/.well-known/openid-configuration
       ← registration_endpoint, authorization_endpoint, token_endpoint

Cursor → POST https://mcp-auth.stage.api.redhat.com/register  (DCR)
       ← client_id: "mcp-client"

Cursor → Authorization Code + PKCE flow → RH SSO login → access token

Cursor → POST http://localhost:8888/mcp
         Authorization: Bearer <token>
       ← MCP response (token forwarded to insights-mcp)
```

In standalone mode the gateway does not enforce authentication itself — it passes the
`Authorization` header through to insights-mcp which validates it. `start.sh` injects a
valid token into `~/.cursor/mcp.json`; use `./cursor-config.sh` to refresh it without
restarting the gateway.

## Troubleshooting

### `go.mod file not found` when building mcp-broker-router

`start.sh` needs the Kuadrant/mcp-gateway source tree. Clone it and checkout a
compatible tag:

```bash
git clone https://github.com/Kuadrant/mcp-gateway.git ../mcp-gateway
cd ../mcp-gateway && git checkout "v${MCP_GATEWAY_VERSION:-0.7.0}"
```

Or point to an existing checkout:

```bash
export MCP_GATEWAY_ROOT=/path/to/mcp-gateway
./start.sh
```

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
./stop.sh
```

Stops the `mcp-envoy` Podman container and the `mcp-broker-router` process. Safe to rerun when nothing is running.

## Limitations of standalone mode

- No dynamic server discovery — server changes require editing `config.yaml` and restarting
- No built-in token enforcement — the gateway passes tokens through; insights-mcp validates them
- Access tokens expire (~5 min) — rerun `./start.sh` or `./cursor-config.sh` and reload Cursor
- No virtual server filtering (per-client tool subsets)
- Single instance — no HA without external load balancing and Redis session store

For full capabilities, see the [Kubernetes installation guide](https://github.com/Kuadrant/mcp-gateway/blob/main/docs/guides/how-to-install-and-configure.md).
