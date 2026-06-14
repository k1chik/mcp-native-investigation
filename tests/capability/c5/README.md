# C5 — Single-server MCP gateway with AuthPolicy (no mcp-gateway)

**Status: done — PASS**

## What this proves

| ID | What it measures | CONNLINK-1026 |
|----|-----------------|---------------|
| C5 | Native `mcp_filter` + `ext_authz` (OPA) + standard `router` is a complete MCP gateway for a single backend — no mcp-gateway or `mcp_router` needed. OPA enforces tool-level policy using only `envoy.filters.http.mcp` dynamic metadata, the same interface Authorino/AuthPolicy uses. | Mentor feedback: single-server MCP use case |

## When this is the right architecture

Single-backend deployments — one MCP server behind Envoy:

- No tool-name prefixing needed (one server, no collision between backends)
- No fan-out aggregation needed
- `mcp_router` and mcp-gateway add zero value here

The Envoy pieces required:

1. `mcp_filter` — parses JSON-RPC body, writes `method` and `params.name` to dynamic metadata under `envoy.filters.http.mcp`
2. `ext_authz` — calls a gRPC policy peer, which reads that metadata and allows or denies. In this lane: **OPA (Open Policy Agent)**, a CNCF policy engine where rules are written in the Rego language. In a Kuadrant deployment: **Authorino**, configured via an `AuthPolicy` CRD. Both implement the same Envoy ext_authz v3 gRPC proto — swapping one for the other is a config change, not a structural one.
3. `router` — standard Envoy HTTP router; forwards to the single backend cluster

## Filter chain comparison

| Lane | Chain | Tool names |
|------|-------|-----------|
| C2 (multi-backend) | `mcp_filter` → `ext_authz` → `mcp_router` | `server1__tool1` (prefix added by `mcp_router`) |
| C5 (single-backend) | `mcp_filter` → `ext_authz` → `router` | `tool1` (plain — no `mcp_router`, no prefix) |

The smoke test asserts the absence of the `server1__` prefix to confirm `mcp_router` is not in the chain.

## Policy note

Both lanes use **OPA (Open Policy Agent)** as the `ext_authz` peer. OPA evaluates a Rego policy and returns allow/deny to Envoy over gRPC.

C2 policy blocks `"server1__tool2"` (prefixed name).
C5 policy blocks `"tool2"` (plain name — no prefix because no `mcp_router`).
The metadata path and the `ext_authz` filter config are identical in both lanes.

## Run

```bash
docker compose up -d
./smoke.sh
docker compose down
```

Or via the top-level runner:

```bash
./run-tests.sh c5
```
