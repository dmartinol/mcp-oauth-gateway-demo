# MCP OAuth Gateway Demo

Example deployments that demonstrate the **OAuth authorization flow** for MCP services using
[Red Hat SSO](https://sso.redhat.com) as the identity provider.

The gateway infrastructure is provided by [MCP Gateway](https://github.com/Kuadrant/mcp-gateway).
Authentication is handled by the hosted [MCP Auth Adapter](https://github.com/velias/mcp-auth-adapter)
(see [MCP Auth Adapter](#mcp-auth-adapter)), which implements DCR and Authorization Code + PKCE
in front of Red Hat SSO. The Kind gateway returns `401` + `WWW-Authenticate` so clients can discover
the adapter and obtain a token (verified with Claude Code; Cursor requires a Bearer workaround on
localhost — see [kind/README.md](kind/README.md)).

[Red Hat Insights MCP](https://github.com/RedHatInsights/insights-mcp) is used as the **example backend
service**. The same infrastructure supports any number of MCP servers — registering a new one requires only a
credential Secret, an HTTPRoute, and an `MCPServerRegistration` object (kind) or a new entry in `config.yaml`
(local).

## Scope and goals

This repository explores two questions:

1. **Can an MCP client authenticate automatically** to a secured MCP gateway using the
   [MCP authorization spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)?
   — The `kind/` deployment answers this: Kuadrant AuthPolicy emits a `WWW-Authenticate` header
   on `401` so clients discover the authorization server and run DCR + PKCE. **Claude Code**
   completes this flow on `http://localhost:8001/mcp`; Cursor has a [known bug](kind/README.md#cursor-shows-needsauth-or-err_ssl_client_auth_cert_needed) on the same URL.

2. **Can an MCP client call the Red Hat Insights API** using a token obtained through the MCP Auth
   Adapter? — Yes, with scopes `api.console api.ocm` on both stage and production. Verified
   end-to-end via Claude Code. Requires an account with the appropriate RBAC roles assigned.

## Current status

| Environment | Auth flow | Insights API | Notes |
|---|---|---|---|
| **Stage** (`env.stage`) | ✅ OAuth via MCP Auth Adapter | ✅ with `api.console api.ocm` scopes on `console.stage.redhat.com` | |
| **Production** (`env.prod`) | ✅ OAuth via MCP Auth Adapter | ✅ with `api.console api.ocm` scopes on `console.redhat.com` | |

Both environments work end-to-end. The authenticated account must have the
[RBAC roles required by each toolset](https://github.com/RedHatInsights/insights-mcp/tree/main#required-permissions-by-toolset)
assigned in its organization (e.g. **Inventory Hosts viewer** for `insights_inventory__list_hosts`).
This applies to both stage and production — assign roles via
[User Access](https://console.redhat.com/iam/user-access/overview).

## MCP Auth Adapter

Both deployments obtain OAuth tokens from the hosted
[MCP Auth Adapter](https://github.com/velias/mcp-auth-adapter) — it does **not** run on your
machine. The adapter sits between MCP clients and [Red Hat SSO](https://sso.redhat.com) and
provides what a plain SSO realm does not expose directly to MCP tooling:

- **OIDC discovery** — `/.well-known/openid-configuration` (authorize, token, registration endpoints)
- **Dynamic Client Registration (DCR)** — clients register without a pre-provisioned OAuth app
- **Authorization Code + PKCE** — browser login against Red Hat SSO, returning a JWT

The adapter issues JWTs scoped for the Red Hat Insights API (`api.console api.ocm`). Each gateway
deployment advertises the adapter as its authorization server in **Protected Resource Metadata**
(PRM) at `/.well-known/oauth-protected-resource`. MCP clients that follow the
[MCP authorization spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
discover the adapter from PRM and run DCR + PKCE automatically; demo scripts also call the adapter
directly via `get-token.py` to obtain tokens for the broker and for clients that cannot complete
OAuth on localhost (e.g. Cursor).

```
MCP client                          MCP Auth Adapter (hosted)
    │  DCR + Authorization Code + PKCE     DCR /authorize /token
    │  (or get-token.py in demo scripts)         │
    └────────────────────────────────────────────┘
                                                 └──► Red Hat SSO
                                                       (sso.stage.redhat.com or sso.redhat.com)
```

**Configuration** — select stage or production via `env.stage` / `env.prod`:

| Variable | Stage | Production |
|---|---|---|
| `MCP_AUTH_BASE` | `https://mcp-auth.stage.api.redhat.com` | `https://mcp-auth.api.redhat.com` |
| SSO realm | `sso.stage.redhat.com` | `sso.redhat.com` |

The gateway stack (Envoy or Istio) validates or forwards the resulting Bearer token; the adapter
is always external. See deployment-specific diagrams in
[`local-deployment/README.md`](local-deployment/README.md#overview) and
[`kind/README.md`](kind/README.md#overview).

## How components connect

The gateway does **not** proxy OAuth traffic to the adapter. Components are linked by metadata
advertisement and by the JWT the client presents on MCP requests:

| Link | What connects | How |
|---|---|---|
| Gateway → Adapter | PRM only | Gateway publishes `MCP_AUTH_BASE` in `/.well-known/oauth-protected-resource` (env vars locally; `MCPGatewayExtension` on kind) |
| Client → Adapter | OAuth | Client reads PRM, then calls the adapter directly for DCR, `/authorize`, and `/token` |
| Adapter → SSO | Identity | Adapter proxies login to Red Hat SSO and returns a JWT |
| Client → Gateway | MCP | Client sends `Authorization: Bearer <JWT>` on `POST /mcp` |
| Gateway → insights-mcp | MCP routing | Broker aggregates `tools/list`; `tools/call` routes to the upstream with the client's token |

```
MCP client ──PRM──► MCP Gateway          (discovery: where to get a token)
     │                    │
     │ OAuth              │ Bearer JWT on /mcp
     ▼                    ▼
MCP Auth Adapter ──► Red Hat SSO    broker-router ──► insights-mcp ──► Insights API
```

On **kind**, Kuadrant AuthPolicy validates the JWT at the Istio gateway before traffic reaches the
broker. On **local-deployment**, the gateway forwards the token and insights-mcp validates it.

## Deployments

Two environments are provided, differing in where authentication is enforced:

| Directory | Stack | Auth enforcement | Use case |
|---|---|---|---|
| [`local-deployment/`](local-deployment/) | Binary + Podman Envoy | Pass-through (each backend validates) | Fast local iteration |
| [`kind/`](kind/) | Kind + Istio + Kuadrant | Kuadrant AuthPolicy at the gateway | Full OAuth flow (Claude Code); Cursor needs Bearer workaround |

### Authentication workflows (overview)

Both deployments use the same **token source** — the [MCP Auth Adapter](#mcp-auth-adapter) runs
DCR + Authorization Code + PKCE in front of Red Hat SSO (`api.console api.ocm` scopes). They differ in
**where the client token is checked** on the way to Insights.

**Obtain a token** (both deployments — via `get-token.py` / `cursor-config.sh`, or client-driven OAuth on kind):

```
MCP client → MCP Auth Adapter (DCR, /authorize, PKCE) → Red Hat SSO → JWT
```

**`local-deployment/`** — gateway pass-through; token injected before connect (no edge `401`):

```
MCP client (Bearer Token) → Envoy :8888 → broker-router :8081 → insights-mcp → Insights API
             (forwards Authorization header; insights-mcp / API validate the JWT)
```

→ Step-by-step OAuth and config: [`local-deployment/README.md`](local-deployment/README.md#authentication-flow)

**`kind/`** — JWT enforced at the Istio gateway; unauthenticated clients get `401` + `WWW-Authenticate`:

```
MCP client → Istio Gateway :8001 → AuthPolicy (JWT) → broker-router → insights-mcp → Insights API
                              ↑
                         401 + Protected Resource Metadata (PRM) if no valid token
```

→ Architecture diagram, Claude Code / Cursor setup: [`kind/README.md`](kind/README.md#overview)

## SSO environment config files

Two env files configure which Red Hat SSO environment to use. **Source one before running any script.**

| File | SSO | Use when |
|---|---|---|
| `env.stage` | `sso.stage.redhat.com` | Stage Insights API (`console.stage.redhat.com`) |
| `env.prod` | `sso.redhat.com` | Production Insights API (`console.redhat.com`) |

Both environments require the authenticated account to have the
[RBAC roles required by each toolset](https://github.com/RedHatInsights/insights-mcp/tree/main#required-permissions-by-toolset)
assigned in its organization — assign them via [User Access](https://console.redhat.com/iam/user-access/overview).

### Usage

```bash
# Production Insights:
source env.prod
cd kind && ./setup.sh

# Stage Insights:
source env.stage
cd kind && ./setup.sh

# Local stack (no Kubernetes):
source env.prod   # or env.stage
cd local-deployment && ./start.sh
```

The env files export these variables (all consumed by both deployment scripts):

| Variable | Stage value | Production value | Purpose |
|---|---|---|---|
| `MCP_AUTH_BASE` | `https://mcp-auth.stage.api.redhat.com` | `https://mcp-auth.api.redhat.com` | MCP Auth Adapter base URL |
| `SSO_ISSUER_URL` | `https://sso.stage.redhat.com/auth/realms/redhat-external` | `https://sso.redhat.com/auth/realms/redhat-external` | JWT issuer for AuthPolicy (kind) |
| `OAUTH_SCOPES` | `api.console api.ocm` | `api.console api.ocm` | Scopes for DCR token request |
| `OAUTH_SCOPES_SUPPORTED` | `api.console,api.ocm,openid,offline_access` | same | Scopes advertised in PRM — see [OAuth scopes](#oauth-scopes) |

## Quick start

**Local (no Kubernetes):**
```bash
source env.stage
cd local-deployment
export GATEWAY_SIGNING_KEY=$(openssl rand -hex 32)
./start.sh
```

**Kind cluster (full auth):**
```bash
source env.prod
cd kind
./setup.sh
```

## OAuth scopes

**Protected Resource Metadata (PRM)** — [RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728) JSON served at
`/.well-known/oauth-protected-resource`. It tells MCP clients which authorization server to use and which
scopes the resource accepts. On kind, the `401` response's `WWW-Authenticate` header points clients at this
endpoint.

Clients request `api.console api.ocm` (set in `env.stage` / `env.prod` as `OAUTH_SCOPES`). The
gateway advertises the same API scopes in PRM (`OAUTH_SCOPES_SUPPORTED`). That is sufficient for the
production Insights API — no extra OIDC client scopes are required in application config.

Use `local-deployment/inspect-token.py` to inspect issued JWT claims when debugging.

## Prerequisites

Both deployments require:
- [Podman](https://podman.io/docs/installation) 4.1+
- Python 3
- A Red Hat account (for RH SSO login during token acquisition)

The `kind/` deployment additionally requires:
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) 0.20+
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)

## Pinned versions

| Component | Version | Source |
|---|---|---|
| MCP Gateway Helm chart | `0.7.0` | `oci://ghcr.io/kuadrant/charts/mcp-gateway` |
| Gateway API CRDs | `v1.5.1` | `github.com/kubernetes-sigs/gateway-api` |
| Istio (`istio/base`, `istiod`) | `1.30.1` | `istio-release.storage.googleapis.com/charts` |
| Kuadrant operator | `1.4.2` | `https://kuadrant.io/helm-charts` |
| Envoy (local-deployment) | `v1.33-latest` | `docker.io/envoyproxy/envoy` |
| insights-mcp image | `latest` (see `kind/charts/insights-mcp/values.yaml`) | `quay.io/redhat-services-prod/insights-management-tenant/insights-mcp/red-hat-lightspeed-mcp` |

Override via env vars in `kind/setup.sh`: `MCP_GATEWAY_VERSION`, `MCP_GATEWAY_GIT_REF`,
`MCP_GATEWAY_EXTENSION_NAME`, `GATEWAY_API_VERSION`, `ISTIO_VERSION`, `KUADRANT_OPERATOR_VERSION`.
For local-deployment: `MCP_GATEWAY_VERSION` (broker source tag), `ENVOY_IMAGE`. For insights-mcp
image tag: `INSIGHTS_MCP_VALUES="--set image.tag=<tag>" ./setup.sh`.

**MCP Gateway 0.7.0:** `MCPGatewayExtension` is named `mcp-gateway-extension`; use `prefix` (not
`toolPrefix`) on `MCPServerRegistration`.

## How the deployments differ

| | `local-deployment` | `kind` |
|---|---|---|
| Auth enforcement | None — insights-mcp validates tokens | Kuadrant AuthPolicy at Istio Gateway |
| Claude Code OAuth | Manual Bearer via `cursor-config.sh` (`:8888`) | Native HTTP OAuth (`:8001`) — works |
| Cursor OAuth | Manual Bearer via `cursor-config.sh` | Broken in Cursor — use Bearer workaround or Claude Code |
| Broker token expiry | ~5 min — restart `start.sh` | ~5 min — run `./refresh-token.sh` |
| Teardown | `pkill` + `podman stop` | `./teardown.sh` |

See [`kind/README.md`](kind/README.md#step-2-configure-mcp-clients) for Claude Code setup
(`claude mcp add mcp-gateway --transport http http://localhost:8001/mcp --scope project`).

## Related

- [MCP Gateway documentation](https://docs.kuadrant.io/mcp-gateway/)
- [MCP Gateway Helm chart](https://ghcr.io/kuadrant/charts/mcp-gateway)
- [MCP authorization spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- [RFC 9728 — OAuth 2.0 Protected Resource Metadata](https://datatracker.ietf.org/doc/html/rfc9728)
