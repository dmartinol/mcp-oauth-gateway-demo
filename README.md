# insights-mcp-gateway-demo

Example deployments of [MCP Gateway](https://github.com/Kuadrant/mcp-gateway) wired to
[Red Hat Insights MCP](https://github.com/RedHatInsights/insights-mcp), showing two deployment
topologies from local development to Kubernetes-with-auth.

## Deployments

| Directory | Stack | Auth | Use case |
|---|---|---|---|
| [`local-deployment/`](local-deployment/) | Binary + Podman Envoy | Pass-through (insights-mcp validates) | Fast local iteration |
| [`kind/`](kind/) | Kind + Istio + Kuadrant | AuthPolicy (JWT at gateway) | Full auth flow, Cursor auto-login |

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
