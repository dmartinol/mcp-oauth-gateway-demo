# MCP OAuth Gateway Demo — Red Hat OpenShift AI

This guide sets up the MCP OAuth gateway experiment on a Red Hat OpenShift AI (RHOAI) cluster. The architecture mirrors the `[kind/](../kind/)` deployment: Istio gateway, Kuadrant AuthPolicy for JWT enforcement, MCP Gateway broker/router, and an MCP server deployed via the MCP Lifecycle Operator.

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


**RHOAI 3.4+ note:** Red Hat Connectivity Link (Kuadrant) is included for Models-as-a-Service use cases. If MaaS is already enabled on your cluster, skip steps 2 and 3 and go to [step 4](#4-install-mcp-gateway-crds-and-controller).

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

## 3. Install MCP Gateway CRDs and Controller

The [Kuadrant MCP Gateway](https://github.com/Kuadrant/mcp-gateway) provides `MCPServerRegistration` and `MCPGatewayExtension` CRDs plus the broker/router/controller.

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

## 10. Verify

```bash
GATEWAY_URL=$(oc get route mcp-gateway -n mcp-gateway-system -o jsonpath='{.spec.host}')

# OAuth discovery — should list the MCP Auth Adapter
curl -s https://$GATEWAY_URL/.well-known/oauth-protected-resource | jq .

# MCP endpoint without token — should return 401 + WWW-Authenticate
curl -i https://$GATEWAY_URL/mcp
```

---

## Configure MCP Clients

### Claude Code (recommended)

```bash
GATEWAY_URL=$(oc get route mcp-gateway -n mcp-gateway-system -o jsonpath='{.spec.host}')
claude mcp add mcp-gateway --transport http https://$GATEWAY_URL/mcp --scope project
```

Then run `/mcp` inside Claude Code to trigger the OAuth flow (DCR + PKCE handled automatically).

### Cursor

Unlike the `kind/` deployment (HTTP + localhost), the RHOAI gateway uses HTTPS on a real hostname, which avoids Cursor's known `ERR_SSL_CLIENT_AUTH_CERT_NEEDED` OAuth bug. Add to `~/.cursor/mcp.json`:

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


| Symptom                      | Check                                                                                                   |
| ---------------------------- | ------------------------------------------------------------------------------------------------------- |
| MCPServer stays Pending      | `kubectl describe mcpserver insights-mcp -n mcp-gateway-demo` — image pull secret or wrong port         |
| 401 with no WWW-Authenticate | MCPGatewayExtension not reconciled — `kubectl logs -n mcp-gateway-system deploy/mcp-gateway-controller` |
| 404 at /mcp                  | `kubectl get mcpserverregistration insights-mcp -n mcp-gateway-demo -o yaml`                            |
| AuthPolicy not enforcing     | `oc get pods -n kuadrant-system` — Authorino running?                                                   |


---

## References

- [Kuadrant MCP Gateway](https://github.com/Kuadrant/mcp-gateway)
- [MCP Lifecycle Operator](https://mcp-lifecycle-operator.sigs.k8s.io/)
- [Red Hat blog: MCP Lifecycle Operator on OpenShift](https://www.redhat.com/en/blog/manage-mcp-servers-red-hat-openshift-mcp-lifecycle-operator)
- [Gateway API v1.4.1](https://gateway-api.sigs.k8s.io/)
- [kind/ deployment](../kind/README.md) — reference implementation this mirrors

