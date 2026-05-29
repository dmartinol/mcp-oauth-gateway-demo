# MCP OAuth Gateway Demo

Example deployments that demonstrate the **OAuth authorization flow** for MCP services using
[Red Hat SSO](https://sso.redhat.com) as the identity provider.

The gateway infrastructure is provided by [MCP Gateway](https://github.com/Kuadrant/mcp-gateway).
Authentication is handled by the [MCP Auth Proxy](https://gitlab.cee.redhat.com/lightforge/mcp-auth-proxy),
exposed at `https://mcp-auth.api.redhat.com`. It implements Dynamic Client Registration (DCR) and
Authorization Code + PKCE on top of Red Hat SSO, so MCP clients like Cursor can authenticate
automatically when they receive a `401` response.

[Red Hat Insights MCP](https://github.com/RedHatInsights/insights-mcp) is used as the **example
backend service**. The same infrastructure supports any number of MCP servers — registering a new
one requires only a credential Secret, an HTTPRoute, and an `MCPServerRegistration` object (kind) or
a new entry in `config.yaml` (local).

## Deployments

Two environments are provided, differing in where authentication is enforced:

| Directory | Stack | Auth enforcement | Use case |
|---|---|---|---|
| [`local-deployment/`](local-deployment/) | Binary + Podman Envoy | Pass-through (each backend validates) | Fast local iteration |
| [`kind/`](kind/) | Kind + Istio + Kuadrant | Kuadrant AuthPolicy at the gateway | Full OAuth flow, Cursor auto-login |

## Pinned versions

| Component | Version | Source |
|---|---|---|
| MCP Gateway Helm chart | `0.6.1` | `oci://ghcr.io/kuadrant/charts/mcp-gateway` |
| Gateway API CRDs | `v1.4.1` | `github.com/kubernetes-sigs/gateway-api` |
| Kuadrant operator | latest stable | `https://kuadrant.io/helm-charts` |
| insights-mcp image | see `kind/charts/insights-mcp/values.yaml` | `quay.io/redhat-services-prod/...` |

When a new MCP Gateway chart is released, update `MCP_GATEWAY_VERSION` in `kind/setup.sh`
and verify the CRD API group and field names haven't changed.

## Quick start

**Local (no Kubernetes):**
```bash
cd local-deployment
./start.sh
```

**Kind cluster (full auth):**
```bash
cd kind
./setup.sh
```

## Prerequisites

Both deployments require:
- [Podman](https://podman.io/docs/installation) 4.1+
- Python 3
- A Red Hat account (for RH SSO login during token acquisition)

The `kind/` deployment additionally requires:
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) 0.20+
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)

## How they differ

| | `local-deployment` | `kind` |
|---|---|---|
| Auth enforcement | None — insights-mcp validates tokens | Kuadrant AuthPolicy at Istio Gateway |
| Cursor 401 / auto-login | No — requires manual `cursor-config.sh` | Yes — Cursor discovers auth server from `WWW-Authenticate` |
| Token refresh | Manual | Cursor manages its own lifecycle |
| Broker token expiry | ~5 min — restart `start.sh` | ~5 min — run `./refresh-token.sh` |
| Teardown | `pkill` + `podman stop` | `./teardown.sh` |

## Related

- [MCP Gateway documentation](https://docs.kuadrant.io/mcp-gateway/)
- [MCP Gateway Helm chart](https://ghcr.io/kuadrant/charts/mcp-gateway)
- [MCP authorization spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
