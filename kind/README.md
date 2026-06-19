# Kind Deployment: MCP OAuth Gateway (with insights-mcp as example backend)

This guide deploys MCP Gateway on a local Kind cluster with Kuadrant authentication enforcement.
Unlike the [local-deployment](../local-deployment/) option, Kuadrant's AuthPolicy enforces
authentication at the gateway layer, so MCP clients (Cursor, MCP Inspector) discover the
authorization server automatically and handle the OAuth flow without manual token injection.

**insights-mcp is the example backend.** The gateway and auth infrastructure (Istio, Kuadrant
AuthPolicy, MCPServerRegistration) are backend-agnostic. To register an additional MCP service,
deploy it in-cluster and apply its own HTTPRoute, credential Secret, and `MCPServerRegistration`
— the gateway and AuthPolicy do not need to change.

## Overview

OAuth tokens come from the hosted [MCP Auth Adapter](../README.md#mcp-auth-adapter) (`MCP_AUTH_BASE`) —
not from the Kind cluster. The gateway advertises the adapter in PRM; Kuadrant AuthPolicy validates
the JWTs it issues. Claude Code completes DCR + PKCE against the adapter automatically; demo scripts
use `get-token.py` for broker credentials and Cursor workarounds.

```
MCP Client (Claude Code / Cursor)
    │
    │  OAuth (DCR + PKCE) ──────────────────────────────┐
    │  Bearer token on MCP requests                      │
    ▼ :8001 (Kind NodePort)                              ▼
 Istio Gateway (mcp-gateway, gateway-system)   MCP Auth Adapter (hosted)
    │  AuthPolicy → validates JWT from adapter       DCR /authorize /token
    │  EnvoyFilter → ext_proc → mcp-broker-router          │
    │                                                        └──► Red Hat SSO
    ├── /mcp         → mcp-gateway service (:8080)   ← tools/list via broker
    └── tools/call   → insights-mcp.mcp.local        ← direct routing with client token
                          │
                       insights-mcp Service (ClusterIP, mcp-system)
                          │
                       insights-mcp Deployment (:8000)
                       quay.io/.../red-hat-lightspeed-mcp
```

**Components:**

| Component | Location | Role |
|---|---|---|
| [MCP Auth Adapter](https://github.com/velias/mcp-auth-adapter) | `MCP_AUTH_BASE` (external) | OAuth authorization server — see [root README](../README.md#mcp-auth-adapter) |
| Istio Gateway | `gateway-system` | Receives MCP client traffic on NodePort 30471 (→ host :8001) |
| Kuadrant AuthPolicy | `gateway-system` | Enforces JWT auth; returns 401 + WWW-Authenticate on failure |
| mcp-broker-router | `mcp-system` | Aggregates tools, serves MCP protocol; advertises adapter in PRM |
| MCPServerRegistration | `mcp-system` | Registers insights-mcp with the broker |
| insights-mcp | `mcp-system` :8000 | Red Hat Insights MCP server (in-cluster) |
| Red Hat SSO | `sso.stage.redhat.com` / `sso.redhat.com` | Identity provider behind the adapter (selected via `env.stage` / `env.prod`) |

## Prerequisites

- [Podman](https://podman.io/docs/installation) 4.1+ running
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) 0.20+ installed (Podman support)
  — `setup.sh` sets `KIND_EXPERIMENTAL_PROVIDER=podman` automatically
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [Helm](https://helm.sh/docs/intro/install/) installed
- Python 3 (for the OAuth login flow)
- Access to `quay.io/redhat-services-prod/insights-management-tenant/insights-mcp/red-hat-lightspeed-mcp`
  (log in with `podman login quay.io` if the image is not publicly accessible)

## SSO environment

Before running `setup.sh`, source an SSO environment file from the **repo root** to select
which Red Hat SSO instance to use:

```bash
# Stage Insights API:
source ../env.stage

# Production Insights API:
source ../env.prod
```

Both files export `MCP_AUTH_BASE`, `SSO_ISSUER_URL`, `OAUTH_SCOPES`, and `OAUTH_SCOPES_SUPPORTED`. The scripts read these
as environment variables; if neither file is sourced the scripts fall back to their stage defaults.

See the [root README](../README.md#sso-environment-config-files) for the full status table.

## Step 1: Run the setup script

```bash
./setup.sh
```

The script will prompt for a Red Hat SSO login once (to obtain the broker token for tool listing).
A browser window opens automatically.

`setup.sh` provisions everything in order:

1. Creates the Kind cluster from `cluster.yaml`
2. Installs Gateway API CRDs and Istio
3. Installs MCP Gateway via Helm (creates Gateway + MCPGatewayExtension + broker deployment)
4. Patches MCPGatewayExtension to advertise the MCP Auth Adapter as the authorization server
5. Installs Kuadrant operator and Authorino
6. Applies the AuthPolicy that enforces Red Hat SSO JWT validation
7. Obtains a broker token (Red Hat SSO login) and stores it in a Secret
8. Deploys insights-mcp in-cluster via the local Helm chart (`charts/insights-mcp`)
9. Creates the HTTPRoute and MCPServerRegistration for insights-mcp

Total time: approximately 10–15 minutes.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `MCP_GATEWAY_VERSION` | `0.7.0` | MCP Gateway Helm chart version |
| `MCP_GATEWAY_GIT_REF` | `v0.7.0` (`v${MCP_GATEWAY_VERSION}`) | Git ref for Kuadrant CR manifest from mcp-gateway repo |
| `MCP_GATEWAY_EXTENSION_NAME` | `mcp-gateway-extension` | MCPGatewayExtension resource name (`mcp-gateway` on chart 0.6.x) |
| `GATEWAY_API_VERSION` | `v1.5.1` | Gateway API CRDs release tag (`standard-install.yaml`) |
| `ISTIO_VERSION` | `1.30.1` | Istio Helm chart version (`istio/base` and `istiod`) |
| `KUADRANT_OPERATOR_VERSION` | `1.4.2` | Kuadrant operator Helm chart version |
| `MCP_PUBLIC_HOST` | `localhost` | Public hostname Cursor connects to (must stay on HTTP for local OAuth) |
| `MCP_PUBLIC_PORT` | `8001` | Host port for the Kind NodePort |
| `MCP_AUTH_BASE` | `https://mcp-auth.stage.api.redhat.com` | MCP Auth Adapter base URL |
| `SSO_ISSUER_URL` | `https://sso.stage.redhat.com/auth/realms/redhat-external` | SSO JWT issuer for AuthPolicy validation |
| `OAUTH_SCOPES_SUPPORTED` | `api.console,api.ocm,openid,offline_access` | Scopes advertised in Protected Resource Metadata (PRM); see [root README](../README.md#oauth-scopes) |
| `CLUSTER_NAME` | `kind` | Kind cluster name |
| `CALLBACK_PORT` | `9090` | Local port for OAuth browser callback |

## Step 2: Configure MCP clients

The gateway URL is always `http://localhost:8001/mcp` (HTTP only — no TLS on the Kind NodePort).
Use `localhost`, not `mcp.127-0-0-1.sslip.io`; public-looking hostnames can trigger
HTTPS upgrades in Chromium-based clients.

### Claude Code (recommended — OAuth works)

From any project directory (or this repo's `local-deployment/`):

```bash
claude mcp add mcp-gateway --transport http http://localhost:8001/mcp --scope project
```

That writes a project-scoped entry to `.mcp.json`:

```json
{
  "mcpServers": {
    "mcp-gateway": {
      "type": "http",
      "url": "http://localhost:8001/mcp"
    }
  }
}
```

In Claude Code, run `/mcp` to authenticate. You should see *Authentication successful.
Reconnected to mcp-gateway.* — then Insights tools (e.g. `insights_inventory__list_hosts`)
work against production (`console.redhat.com`) when using `env.prod`.

No pre-issued token or `cursor-config.sh` is required.

<a id="cursor-known-limitation"></a>

### Cursor (known limitation)

Add the gateway to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "mcp-gateway": {
      "url": "http://localhost:8001/mcp"
    }
  }
}
```

> **Cursor bug — HTTP streamable MCP OAuth on localhost:** On the same URL, Cursor's
> streamableHttp client fails after the initial `401` with `net::ERR_SSL_CLIENT_AUTH_CERT_NEEDED`
> (your logs: `MCP HTTP exchange completed` → `MCP HTTP exchange failed`). The gateway and PRM
> are fine — Claude Code proves end-to-end OAuth works. Cursor never completes login.
>
> **Tracked issues (Cursor forum, 2026):** No ticket names this exact Chromium error string, but
> Cursor staff have confirmed related bugs in the HTTP + OAuth path for localhost MCP:
> [Remote MCP server on localhost fails](https://forum.cursor.com/t/remote-mcp-server-on-localhost-fails/157307)
> (OAuth callback flow; fix claimed on Nightly, still reported broken),
> [Cursor MCP finds tool but report and error (localhost)](https://forum.cursor.com/t/cursor-mcp-finds-tool-but-report-and-eror-localhost/148664),
> [OAuth callback ERR_EMPTY_RESPONSE on localhost](https://forum.cursor.com/t/mcp-oauth-callback-returns-err-empty-response-localhost-callback-handler-sends-no-data/154519).
> Staff workaround in those threads: Bearer header or stdio/`mcp-remote` bridge.
>
> **Workaround:** obtain a dynamic DCR token via the existing `get-token` flow and inject it
> as a Bearer header (see [Troubleshooting](#cursor-shows-needsauth-or-err_ssl_client_auth_cert_needed) below), or
> use Claude Code for OAuth against this gateway.

Restart Cursor or reload MCP servers (**Settings → MCP → Refresh**) after editing `mcp.json`.

## Step 3: Verify

```bash
# Gateway health (without auth — should return 401)
curl -v http://localhost:8001/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
# Expected: 401 with WWW-Authenticate header

# OAuth discovery endpoint (no auth required)
curl -sS http://localhost:8001/.well-known/oauth-protected-resource | jq .
# Expected: authorization_servers contains https://mcp-auth.stage.api.redhat.com

# Broker status
kubectl get mcpsr -n mcp-system
# Expected: insights-mcp READY=True, TOOLS=<count>
```

## Broker credentials

The MCP Gateway **broker** (`mcp-gateway` deployment in `mcp-system`) needs a bearer token to
connect to `insights-mcp` for **`tools/list`** (tool discovery and federation). This is separate
from the token MCP clients use for **`tools/call`**.

| | Broker credential | Client credential |
|---|---|---|
| **Used by** | `mcp-gateway` broker | MCP clients (Cursor, Claude Code, …) |
| **Purpose** | Upstream `tools/list` during registration | Gateway access + `tools/call` to the upstream MCP server |
| **Stored in** | Kubernetes Secret `insights-mcp-token` | Obtained via OAuth at the gateway (AuthPolicy) |
| **Wired via** | `MCPServerRegistration.spec.credentialRef` | Kuadrant AuthPolicy JWT validation |

In this demo, `start-apps.sh` obtains the broker token interactively (`get-token.py` + browser
login) and writes the Secret. The secret must carry the label `mcp.kuadrant.io/secret=true` and
a `token` key (the default expected by `credentialRef`).

This matches the documented Kuadrant MCP Gateway pattern for upstream server credentials. See:

- [MCPServerRegistration CRD — `credentialRef`](https://docs.kuadrant.io/dev/mcp-gateway/docs/reference/mcpserverregistration/)
- [MCP Server Configuration](https://docs.kuadrant.io/dev/mcp-gateway/docs/guides/register-mcp-servers/)
- [Connecting to External MCP Servers](https://docs.kuadrant.io/dev/mcp-gateway/docs/guides/external-mcp-server/) (Step 4–5: Secret + `credentialRef`)
- [MCP Gateway documentation](https://docs.kuadrant.io/mcp-gateway/)

For production, replace the interactive login with a service-account token (client credentials or
automated refresh) stored in a secrets manager — see the root
[README](../README.md) for the deployment comparison.

## Broker token expiry

The broker uses a short-lived OAuth token to authenticate with insights-mcp for `tools/list`.
When this token expires (~5 minutes), tool discovery fails. Refresh it:

```bash
./refresh-token.sh
```

This opens a browser for Red Hat SSO login, updates the Kubernetes Secret, and restarts the
broker pod to reload credentials.

> **Client tokens** (what MCP clients use for `tools/call`) are obtained via the OAuth flow
> described in Step 2. Claude Code manages refresh automatically; Cursor requires a
> workaround today (see Troubleshooting).

## How authentication works (vs local-deployment)

Both paths use the same hosted [MCP Auth Adapter](../README.md#mcp-auth-adapter) for token issuance.
They differ in whether the gateway enforces the JWT before traffic reaches the broker:

| | local-deployment | kind |
|---|---|---|
| Auth enforcement | None (broker passes everything) | Kuadrant AuthPolicy at Istio |
| Client 401 | Only from insights-mcp (missing headers) | From gateway, before hitting broker |
| WWW-Authenticate | Not set | Set by AuthPolicy with resource_metadata URL |
| Claude Code OAuth | Manual Bearer via `cursor-config.sh` on `:8888` | Automatic on `:8001` via `/mcp` |
| Cursor OAuth | Manual Bearer via `cursor-config.sh` | Broken — `ERR_SSL_CLIENT_AUTH_CERT_NEEDED` (use Bearer workaround) |
| Broker token refresh | Manual — rerun `cursor-config.sh` | ~5 min — run `./refresh-token.sh` |

## Manifests

| File | Purpose |
|---|---|
| `cluster.yaml` | Kind cluster config — maps NodePort 30471 to host port 8001 |
| `charts/insights-mcp/` | Helm chart — deploys the `red-hat-lightspeed-mcp` image in-cluster |
| `manifests/authpolicy.yaml` | Kuadrant AuthPolicy — JWT validation + 401 + WWW-Authenticate |
| `manifests/insights-mcp-httproute.yaml` | HTTPRoute attaching to `mcps` listener, backend port 8000 |
| `manifests/mcpserverregistration.yaml` | Registers insights-mcp with broker; references broker token Secret |

## Troubleshooting

### Cursor shows `needsAuth` or `ERR_SSL_CLIENT_AUTH_CERT_NEEDED`

**Confirmed:** The gateway and OAuth metadata are correct — the same
`http://localhost:8001/mcp` URL works in **Claude Code** with native HTTP OAuth
(`claude mcp add … --transport http`). The failure is Cursor-specific.

See [tracked Cursor forum threads](#cursor-known-limitation) in Step 2 (localhost HTTP MCP OAuth;
`ERR_SSL_CLIENT_AUTH_CERT_NEEDED` is the Chromium symptom, not a separate gateway misconfig).

1. Confirm `~/.cursor/mcp.json` uses `http://localhost:8001/mcp` (not `sslip.io`).
2. Check **View → Output → MCP: mcp-gateway** — if you see
   `MCP HTTP exchange completed` followed by `ERR_SSL_CLIENT_AUTH_CERT_NEEDED`,
   Cursor's streamableHttp client failed on the second hop (not the gateway).
3. **Prefer Claude Code** for OAuth against this Kind deployment (see Step 2).
4. **Cursor workaround** — dynamic DCR token as Bearer header:

```bash
source ../env.prod    # or ../env.stage
./cursor-config.sh
# Reload MCP servers in Cursor
```

5. Verify the discovery chain from a terminal:

```bash
curl -sS http://localhost:8001/.well-known/oauth-protected-resource | jq .
curl -sv http://localhost:8001/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>&1 | grep -i www-authenticate
# Expected: resource_metadata=http://localhost:8001/.well-known/oauth-protected-resource
```

If you see `ERR_SSL_CLIENT_AUTH_CERT_NEEDED` in Cursor logs, re-point the cluster
at `localhost` if needed (`./reconfigure-public-host.sh`), then use the Bearer
workaround above or switch to Claude Code — do not change the URL to a bridge IP.

### `kubectl wait` times out on MCPGatewayExtension

```bash
kubectl get mcpgatewayextension -n mcp-system
kubectl describe mcpgatewayextension mcp-gateway-extension -n mcp-system
kubectl logs -n mcp-system deployment/mcp-gateway-controller
```

> Chart **0.7.0+** names the resource `mcp-gateway-extension` (0.6.x used `mcp-gateway`).
> Override with `MCP_GATEWAY_EXTENSION_NAME` if your release differs.

### Claude Code: `Got new credentials, but mcp-gateway rejected them on reconnect`

OAuth succeeded but the gateway rejected the Bearer token. Common cause: **PRM and AuthPolicy
point at different SSO environments** (e.g. `env.prod` for PRM but cluster still has stage
issuer from an earlier `setup.sh`).

Check:

```bash
kubectl get authpolicy mcp-auth -n gateway-system -o jsonpath='{.spec.defaults.rules.authentication.redhat-sso.jwt.issuerUrl}'; echo
curl -sS http://localhost:8001/.well-known/oauth-protected-resource | jq .authorization_servers
```

Both must match your sourced env file (`MCP_AUTH_BASE` in PRM, `SSO_ISSUER_URL` in AuthPolicy).

Fix:

```bash
source ../env.prod   # or env.stage — use one file consistently
./configure-oauth-metadata.sh
```

If you see `no matches for kind "AuthPolicy"`, Kuadrant is not installed — run `./setup.sh`
first (or `./apply-authpolicy.sh` after setup completes).

Then `/mcp` → **Authenticate** once more.

Authorino logs (`kubectl logs -n kuadrant-system deployment/authorino --tail=20`) may show
`failed to verify id token signature` or issuer mismatch when `SSO_ISSUER_URL` is wrong.

### Claude Code / MCP client: `JSON Parse error: Unexpected identifier "Hello"`

OAuth discovery failed because Protected Resource Metadata had empty `authorization_servers`.
Chart **0.7.0+** owns the broker deployment — `kubectl set env` is reverted on reconcile.
Re-apply PRM via `MCPGatewayExtension.spec.oauthProtectedResource`:

```bash
source ../env.prod   # or env.stage
./configure-oauth-metadata.sh
# or: ./reconfigure-public-host.sh
```

Verify:

```bash
curl -sS http://localhost:8001/.well-known/oauth-protected-resource | jq .
# authorization_servers must list your MCP_AUTH_BASE
```

Then retry **Authenticate** in Claude Code (`/mcp`).

### AuthPolicy not enforcing (no 401 returned)

```bash
kubectl get authpolicy -n gateway-system
kubectl describe authpolicy mcp-auth -n gateway-system
# Kuadrant must show the policy as "Enforced"
```

### MCPServerRegistration not Ready

```bash
kubectl describe mcpsr insights-mcp -n mcp-system
```

Common causes:
- Broker token expired — run `./refresh-token.sh`
- insights-mcp pod not running — check image pull and container startup:
  ```bash
  kubectl get pods -n mcp-system -l app.kubernetes.io/name=insights-mcp
  kubectl logs -n mcp-system deploy/insights-mcp
  ```

### Host IP detection fails

Set `HOST_IP` manually and re-apply the service manifest:

```bash
export HOST_IP=<your-host-ip>
sed "s/HOST_IP_PLACEHOLDER/${HOST_IP}/g" manifests/insights-mcp-service.yaml | kubectl apply -f -
```

### Port 8001 in use on the host

Change `MCP_PUBLIC_PORT` and update the Kind cluster's `extraPortMappings` in `cluster.yaml`
to use a different `hostPort` before creating the cluster.

## Stopping

```bash
kind delete cluster --name kind
```

This removes all cluster resources. The insights-mcp process on the host is not affected.

## Limitations

- Broker token expires in ~5 minutes — refresh manually with `./refresh-token.sh`
- insights-mcp image env vars are not documented here — consult the image or run `kubectl exec` to discover them
- Single-node Kind cluster — no HA
- No HTTPS (HTTP only for local development)

For production, see the [Kubernetes installation guide](https://github.com/Kuadrant/mcp-gateway/blob/main/docs/guides/how-to-install-and-configure.md).

## Why not `make local-env-setup`?

The repo ships Makefile targets (`make local-env-setup`, `make local-env-setup-olm`) that also
spin up a Kind cluster with MCP Gateway. They were not used here for three reasons:

1. **Builds from source** — `setup-cluster-base` runs `build-and-load-image`, which compiles the
   binary and loads it into Kind. This guide targets published images via the Helm chart
   (`oci://ghcr.io/kuadrant/charts/mcp-gateway`), which is the operator/end-user path.

2. **No insights-mcp wiring** — the Makefile targets deploy internal test servers
   (`everything-server`, `deploy-example-minimal`). Wiring an external host-resident MCP server
   requires the Service + Endpoints + HTTPRoute pattern in `manifests/`, which is not covered.

3. **Kuadrant via OLM** — `make local-env-setup-olm` does install Kuadrant (required for
   AuthPolicy enforcement), but uses OLM rather than Helm. The Helm path in `setup.sh` is
   simpler for a standalone deployment and matches the production install guide.

If you are already working inside the repo and want to iterate on gateway code, the Makefile
approach is better. Apply the insights-mcp manifests on top after `make local-env-setup-olm`:

```bash
# From the repo root — builds from source, installs Kuadrant via OLM
make local-env-setup-olm

# Then deploy insights-mcp and wire it (from this directory)
helm upgrade -i insights-mcp charts/insights-mcp -n mcp-system

kubectl apply -f manifests/insights-mcp-httproute.yaml
kubectl apply -f manifests/authpolicy.yaml

# Create broker token Secret (browser login)
TOKEN=$(python3 ../local-deployment/get-token.py --mcp-auth-base https://mcp-auth.stage.api.redhat.com --callback-port 9090)
kubectl create secret generic insights-mcp-token --from-literal=token="${TOKEN}" -n mcp-system

kubectl apply -f manifests/mcpserverregistration.yaml
```
