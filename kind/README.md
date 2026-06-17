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

```
MCP Client (Cursor)
    │
    ▼ :8001 (Kind NodePort)
 Istio Gateway (mcp-gateway, gateway-system)
    │  AuthPolicy → validates JWT from Red Hat SSO (automatic 401 + WWW-Authenticate)
    │  EnvoyFilter → ext_proc → mcp-broker-router (mcp-system)
    │
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
| Istio Gateway | `gateway-system` | Receives MCP client traffic on NodePort 30471 (→ host :8001) |
| Kuadrant AuthPolicy | `gateway-system` | Enforces JWT auth; returns 401 + WWW-Authenticate on failure |
| mcp-broker-router | `mcp-system` | Aggregates tools, serves MCP protocol |
| MCPServerRegistration | `mcp-system` | Registers insights-mcp with the broker |
| insights-mcp | `mcp-system` :8000 | Red Hat Insights MCP server (in-cluster) |

## Prerequisites

- [Podman](https://podman.io/docs/installation) 4.1+ running
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) 0.20+ installed (Podman support)
  — `setup.sh` sets `KIND_EXPERIMENTAL_PROVIDER=podman` automatically
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [Helm](https://helm.sh/docs/intro/install/) installed
- Python 3 (for the OAuth login flow)
- Access to `quay.io/redhat-services-prod/insights-management-tenant/insights-mcp/red-hat-lightspeed-mcp`
  (log in with `podman login quay.io` if the image is not publicly accessible)

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
| `MCP_GATEWAY_VERSION` | `0.6.1` | MCP Gateway Helm chart version |
| `MCP_PUBLIC_HOST` | `localhost` | Public hostname Cursor connects to (must stay on HTTP for local OAuth) |
| `MCP_PUBLIC_PORT` | `8001` | Host port for the Kind NodePort |
| `MCP_AUTH_BASE` | `https://mcp-auth.stage.api.redhat.com` | MCP Auth Adapter base URL |
| `SSO_ISSUER_URL` | `https://sso.stage.redhat.com/auth/realms/redhat-external` | SSO JWT issuer for AuthPolicy validation |
| `CLUSTER_NAME` | `kind` | Kind cluster name |
| `CALLBACK_PORT` | `9090` | Local port for OAuth browser callback |

### Configuring insights-mcp

The insights-mcp container may need credentials to call upstream Red Hat Insights APIs.
Override the chart values before running `setup.sh`:

```bash
# Option A: pass values inline
INSIGHTS_MCP_VALUES="--set env[0].name=OFFLINE_TOKEN --set env[0].value=<token>" ./setup.sh

# Option B: use a values file (recommended for multiple vars)
cat > my-insights-values.yaml <<EOF
env:
  - name: OFFLINE_TOKEN
    value: "<your-token>"
EOF
INSIGHTS_MCP_VALUES="-f my-insights-values.yaml" ./setup.sh
```

If the image requires a quay.io pull secret, create it first:

```bash
kubectl create namespace mcp-system 2>/dev/null || true
kubectl create secret docker-registry quay-pull-secret \
  --docker-server=quay.io \
  --docker-username=<username> \
  --docker-password=<password> \
  -n mcp-system
```

Then reference it in your values file:

```yaml
imagePullSecrets:
  - name: quay-pull-secret
```

> The exact environment variable names depend on the image. Check the image documentation
> or inspect the running container with `kubectl exec -n mcp-system deploy/insights-mcp -- env`.

## Step 2: Configure Cursor

Add the gateway URL to Cursor's MCP configuration (`~/.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "mcp-gateway": {
      "url": "http://localhost:8001/mcp"
    }
  }
}
```

> Use `localhost`, not `mcp.127-0-0-1.sslip.io`. Cursor's Chromium stack may
> HTTPS-upgrade public-looking hostnames before OAuth starts, which fails against
> this HTTP-only gateway (`ERR_SSL_CLIENT_AUTH_CERT_NEEDED`) and never opens the
> login browser.

> **No token needed.** When Cursor connects and receives the `401 Unauthorized` response, it reads the
> `WWW-Authenticate` header, discovers the authorization server at
> `https://mcp-auth.stage.api.redhat.com`, performs DCR + Authorization Code + PKCE automatically,
> and completes the Red Hat SSO login in a browser window.

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

## Broker token expiry

The broker uses a short-lived OAuth token to authenticate with insights-mcp for `tools/list`.
When this token expires (~5 minutes), tool discovery fails. Refresh it:

```bash
./refresh-token.sh
```

This opens a browser for Red Hat SSO login, updates the Kubernetes Secret, and restarts the
broker pod to reload credentials.

> **Client tokens** (what Cursor uses for `tools/call`) are managed by Cursor itself and
> refreshed automatically via the MCP auth flow.

## How authentication works (vs local-deployment)

| | local-deployment | kind |
|---|---|---|
| Auth enforcement | None (broker passes everything) | Kuadrant AuthPolicy at Istio |
| Client 401 | Only from insights-mcp (missing headers) | From gateway, before hitting broker |
| WWW-Authenticate | Not set | Set by AuthPolicy with resource_metadata URL |
| Cursor OAuth flow | Manual — requires `cursor-config.sh` | Automatic — Cursor discovers auth server from 401 |
| Token refresh | Manual — rerun `cursor-config.sh` | Automatic — Cursor manages its own token lifecycle |

## Manifests

| File | Purpose |
|---|---|
| `cluster.yaml` | Kind cluster config — maps NodePort 30471 to host port 8001 |
| `charts/insights-mcp/` | Helm chart — deploys the `red-hat-lightspeed-mcp` image in-cluster |
| `manifests/authpolicy.yaml` | Kuadrant AuthPolicy — JWT validation + 401 + WWW-Authenticate |
| `manifests/insights-mcp-httproute.yaml` | HTTPRoute attaching to `mcps` listener, backend port 8000 |
| `manifests/mcpserverregistration.yaml` | Registers insights-mcp with broker; references broker token Secret |

## Troubleshooting

### Cursor shows `needsAuth` but never opens a browser

1. Confirm `~/.cursor/mcp.json` uses `http://localhost:8001/mcp` (not `sslip.io`).
2. Reload MCP servers, then click **Needs authentication** under the server name (not Connect).
3. Check **View → Output → MCP: mcp-gateway** for `MCP OAuth redirect to authorization`.
4. Verify the discovery chain from a terminal:

```bash
curl -sS http://localhost:8001/.well-known/oauth-protected-resource | jq .
curl -sv http://localhost:8001/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>&1 | grep -i www-authenticate
# Expected: resource_metadata=http://localhost:8001/.well-known/oauth-protected-resource
```

If you see `ERR_SSL_CLIENT_AUTH_CERT_NEEDED` in Cursor logs, the OAuth metadata URLs
are still pointing at a public-looking hostname (`sslip.io`). Re-point the cluster
and Cursor config at `localhost`:

```bash
./reconfigure-public-host.sh
# then set url to http://localhost:8001/mcp in ~/.cursor/mcp.json and reload MCP
```

### `kubectl wait` times out on MCPGatewayExtension

```bash
kubectl describe mcpgatewayextension mcp-gateway -n mcp-system
kubectl logs -n mcp-system deployment/mcp-gateway-controller
```

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
- insights-mcp missing required env vars — inspect what the container exposes and set them
  via a values file (see **Configuring insights-mcp** above)

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

## Test Output: Token Comparison

**Token comparison: `mcp-client` (Cursor) vs `ocm-cli`**

All differences are JWT claims:

- `scope`: Cursor gets `openid` only — `ocm-cli` gets `openid roles web-origins` (`web-origins` is a CORS scope and not relevant here; the key missing scope is `roles`)
- `realm_access.roles`: absent in Cursor token — `ocm-cli` carries `redhat:employees`, `portal_manage_subscriptions`, `portal_system_management`, etc.
- `account_number`: absent in Cursor token — `ocm-cli` has `***`
- `org_id`: absent in Cursor token — `ocm-cli` has `***`
- `is_active`: absent in Cursor token — `ocm-cli` has `true`
- `preferred_username` / `email`: absent in Cursor token — `ocm-cli` has `***`
- `aud`: absent in Cursor token — `ocm-cli` targets `ocm-cli` and `account`

**Root cause:** `console.redhat.com` uses `account_number`, `org_id`, and `realm_access.roles` for
RBAC enforcement. The `mcp-client` SSO client doesn't request the `roles` and `web-origins` scopes,
so SSO strips those claims. The API receives a token it can't make an authorization decision on → 403.

**Fix needed:** the `mcp-client` OAuth client in RH SSO needs `roles` added to its default scopes,
and `account_number`/`org_id` protocol mappers configured if not already present.
