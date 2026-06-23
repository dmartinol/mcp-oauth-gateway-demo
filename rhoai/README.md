# MCP OAuth Gateway Demo — Red Hat OpenShift AI

This guide sets up the **MCP OAuth Gateway Demo** on a Red Hat OpenShift AI (RHOAI) cluster. The architecture mirrors the `[kind/](../kind/)` deployment: Istio gateway, Kuadrant AuthPolicy for JWT enforcement, [MCP Gateway](https://github.com/Kuadrant/mcp-gateway) broker/router, and an MCP server deployed via the MCP Lifecycle Operator.

### MCP OAuth Gateway Demo vs MCP Gateway

These are **not** two different gateway products:

| Name | What it is |
|------|------------|
| **MCP Gateway** | Kuadrant / [Red Hat Connectivity Link](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/) product — broker, router, `MCPServerRegistration` / `MCPGatewayExtension` CRDs, and controller |
| **MCP OAuth Gateway Demo** (this repo) | A proof-of-concept layered on MCP Gateway — OAuth discovery (PRM), DCR + PKCE via the external [MCP Auth Adapter](https://github.com/velias/mcp-auth-adapter), and JWT enforcement with Kuadrant `AuthPolicy` |

This guide deploys **application manifests** (`insights-mcp`, `MCPServerRegistration`, `AuthPolicy`, OAuth metadata) on top of an existing MCP Gateway installation. It does **not** ship a separate gateway implementation.

```
rhoai/
  manifests/
    kustomization.yaml          # applies insights-mcp + registration
    servicemesh-controlplane.yaml
    kuadrant.yaml
    insights-mcp.yaml           # ServiceAccount + MCPServer
    insights-mcp-registration.yaml  # HTTPRoute + MCPServerRegistration
    authpolicy.yaml             # requires envsubst for SSO_ISSUER_URL
  configure-oauth-metadata.sh  # patches MCPGatewayExtension (mirrors kind/)
  README.md
```

## Prerequisites


| Requirement             | Notes                                                           |
| ----------------------- | --------------------------------------------------------------- |
| OpenShift 4.14+ cluster | With cluster-admin access                                       |
| RHOAI 3.x installed     | Operator installed from OperatorHub                             |
| `oc` CLI                | Logged in: `oc login ...`                                       |
| `kubectl`               | Or alias `kubectl=oc`                                           |
| `curl`, `jq`            | For token inspection                                            |
| `envsubst`              | Usually bundled with `gettext`; `brew install gettext` on macOS |


**RHOAI 3.4+ note:** Red Hat Connectivity Link (Kuadrant) is included for Models-as-a-Service use cases. If MaaS is already enabled, skip [step 2](#2-install-kuadrant-operator). If the **MCP Gateway operator** is already installed (OperatorHub / OLM), skip [step 3](#3-install-mcp-gateway) and go to [step 4](#4-install-mcp-lifecycle-operator).

> **Do not run step 3's manual install if MCP Gateway is already on the cluster.** A second controller (raw `kubectl apply -k` from upstream `main` alongside the OLM operator) will fight over the same CRDs and `MCPGatewayExtension` resources. Only one MCP Gateway controller should be installed.

Select your SSO environment before running any command:

```bash
source ../env.stage   # or ../env.prod
```

## Architecture

```
MCP Client (Claude Code / Cursor)
  │
  ▼
OpenShift Route / Istio Ingress Gateway  (:443)
  │  Kuadrant AuthPolicy — JWT validation against Red Hat SSO
  ▼
MCP Gateway Broker  (Kuadrant mcp-gateway)
  │  MCPServerRegistration → HTTPRoute → Service
  ▼
insights-mcp pod  (managed by MCP Lifecycle Operator)
```

OAuth discovery and PKCE are handled by the external **MCP Auth Adapter** (same as `kind/`).

---

## 1. Install Istio / OpenShift Service Mesh

Install via OperatorHub (**Operators → OperatorHub → "OpenShift Service Mesh" → Install**), then apply the control plane:

```bash
oc apply -f manifests/servicemesh-controlplane.yaml
oc wait --for=condition=Ready smcp/basic -n istio-system --timeout=5m
```

## 2. Install Kuadrant Operator

> **Skip if RHOAI 3.4+ MaaS is enabled** — Kuadrant is already present.

Install via OperatorHub (**Operators → OperatorHub → "Kuadrant" → Install, all namespaces**), then create the instance:

```bash
oc apply -f manifests/kuadrant.yaml
oc get pods -n kuadrant-system   # wait for Limitador + Authorino to be Running
```

## 3. Install MCP Gateway

Skip this step if MCP Gateway is already installed. Check first:

```bash
oc get csv -A | grep mcp-gateway          # OLM install
oc get crds | grep mcp.kuadrant.io      # CRDs present
```

### Path A — OLM / OperatorHub (recommended on OpenShift / RHOAI)

Install via Operator Lifecycle Manager as documented in [Installing the MCP gateway with OLM](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/installing_the_mcp_gateway/mcp-gateway-install#proc-mcp-gateway-install-olm_command) (Red Hat Connectivity Link). Then:

1. Create a `Gateway` with listeners ([step 1.2](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/installing_the_mcp_gateway/mcp-gateway-install#proc-creating-a-gateway-object-for-your-mcp-gateway)).
2. Create an `MCPGatewayExtension` targeting that Gateway ([step 1.5](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/installing_the_mcp_gateway/mcp-gateway-install#proc-applying-the-mcpgatewayextension-custom-resource)).

This demo assumes the Gateway is named `mcp-gateway` in namespace `mcp-gateway-system`. If your OLM install uses different names, update `manifests/authpolicy.yaml`, `manifests/insights-mcp-registration.yaml`, and the `MCP_GATEWAY_NAMESPACE` / route commands in later steps.

For OAuth, you may need `spec.httpRouteManagement: Disabled` on `MCPGatewayExtension` and a custom `HTTPRoute` (see Connectivity Link release notes for your operator version). The demo's `insights-mcp-registration.yaml` already defines its own `HTTPRoute`.

### Path B — Manual install (clusters without the operator only)

Upstream Kuadrant install bundle — **not** for clusters that already have the MCP Gateway operator:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml
kubectl apply -k 'https://github.com/Kuadrant/mcp-gateway/config/install?ref=main'
```

> For OpenShift-specific security context overrides, see [config/openshift/README.md](https://github.com/Kuadrant/mcp-gateway/tree/main/config/openshift) upstream.

```bash
kubectl get crds | grep mcp.kuadrant.io
# Expected: mcpserverregistrations.mcp.kuadrant.io
#           mcpgatewayextensions.mcp.kuadrant.io
```

The `kind/` deployment uses a **pinned Helm chart** (`oci://ghcr.io/kuadrant/charts/mcp-gateway` at `0.7.0`) instead — closer to a reproducible release than `ref=main`.

## 4. Install MCP Lifecycle Operator

The [MCP Lifecycle Operator](https://mcp-lifecycle-operator.sigs.k8s.io/) (v0.1.0, developer preview) manages `MCPServer` resources — Deployment, Service, health checks, and security hardening.

```bash
kubectl apply -f https://raw.githubusercontent.com/openshift/mcp-lifecycle-operator/release-v0.1.0/dist/install.yaml
kubectl get pods -n mcp-lifecycle-operator-system
```

## 5. Create the Demo Namespace

```bash
oc new-project mcp-gateway-demo
oc label namespace mcp-gateway-demo istio-injection=enabled
```

## 6. Deploy Application Manifests

Apply the kustomize base — ServiceAccount, MCPServer, HTTPRoute, and MCPServerRegistration:

```bash
kubectl apply -k manifests/
```

Wait for the MCP server to pass its handshake probe:

```bash
kubectl get mcpserver insights-mcp -n mcp-gateway-demo -w
# Ready=True when the operator confirms the MCP handshake
```

## 7. Apply JWT AuthPolicy

`authpolicy.yaml` uses `${SSO_ISSUER_URL}` — sourced from your env file:

```bash
envsubst < manifests/authpolicy.yaml | kubectl apply -f -
```

## 8. Expose the Gateway via OpenShift Route

```bash
GATEWAY_SVC=$(oc get svc -n mcp-gateway-system -l app=mcp-gateway-broker -o name | head -1)
oc create route edge mcp-gateway \
  --service=${GATEWAY_SVC#*/} \
  --namespace=mcp-gateway-system \
  --port=8080

GATEWAY_URL=$(oc get route mcp-gateway -n mcp-gateway-system -o jsonpath='{.spec.host}')
echo "Gateway: https://$GATEWAY_URL/mcp"
```

## 9. Configure OAuth Protected Resource Metadata

Patches the `MCPGatewayExtension` so the broker advertises the MCP Auth Adapter at `/.well-known/oauth-protected-resource`. Creates the resource if the install bundle did not:

```bash
./configure-oauth-metadata.sh
```

Requires `MCP_AUTH_BASE` and `OAUTH_SCOPES_SUPPORTED` from your sourced env file.

Run this **after** the Route exists (step 8) so the script can read the public hostname. The
`resource` field in PRM must match the MCP client URL exactly (e.g. `https://<route-host>/mcp`).
See [OAuth discovery notes](#oauth-discovery-notes) for how this compares to `kind/`.

## 10. Verify

```bash
GATEWAY_URL=$(oc get route mcp-gateway -n mcp-gateway-system -o jsonpath='{.spec.host}')

# OAuth discovery — should list the MCP Auth Adapter; resource must match https://$GATEWAY_URL/mcp
curl -s https://$GATEWAY_URL/.well-known/oauth-protected-resource | jq .

# MCP endpoint without token — should return 401 (JWT required)
curl -i https://$GATEWAY_URL/mcp
```

---

## OAuth discovery notes

This deployment configures **Protected Resource Metadata (PRM)** on `MCPGatewayExtension` via
`configure-oauth-metadata.sh`. That is the piece MCP HTTP clients need most: PRM advertises the
protected `resource` URL and the MCP Auth Adapter as `authorization_servers`.

### Comparison with `kind/`

| | RHOAI (this guide) | `kind/` |
|---|---|---|
| Public URL | OpenShift Route hostname (HTTPS) | `localhost:8001` or `MCP_PUBLIC_URL` (e.g. ngrok) |
| PRM `resource` | Set from Route in `configure-oauth-metadata.sh` | Set via `configure-oauth-metadata.sh` / `reconfigure-public-host.sh` |
| Tunnel / ngrok | Not needed | See [kind/README — Exposing via ngrok](../kind/README.md#exposing-via-ngrok-https) |
| `WWW-Authenticate` on 401 | Not configured in `manifests/authpolicy.yaml` | Configured — points clients at PRM (`resource_metadata=...`) |
| PRM path unauthenticated | Not explicitly excluded in AuthPolicy (verify — see below) | AuthPolicy skips `/.well-known` paths |

If the Route hostname changes, re-run `./configure-oauth-metadata.sh` — there is no
`reconfigure-public-host.sh` equivalent here; the Route host is the source of truth.

### What each client type needs

| Client | PRM `resource` correct? | `WWW-Authenticate` on 401? |
|---|---|---|
| **Cursor** / **Claude Code** (HTTP OAuth) | **Required** — client URL must match PRM `resource` | Helpful; clients also fetch `/.well-known/oauth-protected-resource` directly |
| **Bearer workaround** (manual token in `mcp.json`) | No | No |
| **Manual OAuth UIs** (e.g. Auth URL + Token URL only) | Partial — uses adapter OIDC endpoints, not PRM | No |

PRM alignment is what fixed the ngrok mismatch on `kind/` (`Protected resource … does not match
expected …`). On RHOAI, step 9 handles that automatically from the Route — no `MCP_PUBLIC_URL`
needed for a normal install.

### Verify PRM is reachable without a token

Unlike `kind/manifests/authpolicy.yaml`, the RHOAI AuthPolicy does not yet exclude
`/.well-known` from JWT enforcement. Confirm discovery works before testing OAuth clients:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://$GATEWAY_URL/.well-known/oauth-protected-resource
# Expect 200 — if 401, PRM is behind AuthPolicy and HTTP OAuth clients may fail discovery
```

The `WWW-Authenticate` header on `POST /mcp` without a token is **optional** for Cursor and
Claude Code when PRM is public and `resource` matches the client URL. It is **not** used by
Bearer-token or manual-OAuth clients. The `kind/` deployment includes it for spec completeness;
this guide does not configure it in manifests by design (minimal demo scope).

---

## Configure MCP Clients

### Claude Code (recommended)

```bash
GATEWAY_URL=$(oc get route mcp-gateway -n mcp-gateway-system -o jsonpath='{.spec.host}')
claude mcp add mcp-gateway --transport http https://$GATEWAY_URL/mcp --scope project
```

Then run `/mcp` inside Claude Code to trigger the OAuth flow (DCR + PKCE handled automatically).

### Cursor

Unlike the `kind/` deployment (HTTP + localhost), the RHOAI gateway uses HTTPS on a real
OpenShift Route hostname — no ngrok tunnel or `MCP_PUBLIC_URL` reconfiguration needed. Add to
`~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "mcp-gateway": {
      "url": "https://<gateway-route-host>/mcp"
    }
  }
}
```

Reload via **Settings → MCP → Refresh**.

For OAuth discovery behaviour (PRM, `WWW-Authenticate`, differences from `kind/`), see
[OAuth discovery notes](#oauth-discovery-notes) in the RHOAI guide.

If Cursor still fails OAuth, fall back to a Bearer token:

```bash
source ../env.stage   # or ../env.prod
python3 ../local-deployment/get-token.py
```

Then inject it in `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "mcp-gateway": {
      "url": "https://<gateway-route-host>/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

---

## Troubleshooting


| Symptom | Check |
| --- | --- |
| MCPServer stays Pending | `kubectl describe mcpserver insights-mcp -n mcp-gateway-demo` — image pull secret or wrong port |
| Protected resource mismatch (Cursor) | PRM `resource` must equal client URL — re-run `./configure-oauth-metadata.sh` after Route changes; see [OAuth discovery notes](#oauth-discovery-notes) |
| PRM returns 401 | AuthPolicy may be enforcing JWT on `/.well-known` — see [OAuth discovery notes](#oauth-discovery-notes) |
| 404 at /mcp | `kubectl get mcpserverregistration insights-mcp -n mcp-gateway-demo -o yaml` |
| AuthPolicy not enforcing | `oc get pods -n kuadrant-system` — Authorino running? |


---

## References

- [Installing the MCP gateway (Red Hat Connectivity Link / OLM)](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/installing_the_mcp_gateway/mcp-gateway-install)
- [Kuadrant MCP Gateway](https://github.com/Kuadrant/mcp-gateway)
- [MCP Lifecycle Operator](https://mcp-lifecycle-operator.sigs.k8s.io/)
- [Red Hat blog: MCP Lifecycle Operator on OpenShift](https://www.redhat.com/en/blog/manage-mcp-servers-red-hat-openshift-mcp-lifecycle-operator)
- [Gateway API v1.4.1](https://gateway-api.sigs.k8s.io/)
- [kind/ deployment](../kind/README.md) — reference implementation this mirrors

