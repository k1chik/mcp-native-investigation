# C4b: per-user tool list

**Claim:** `mcp_router` prefix behavior with user-specific tool lists (two listener configs on bare Envoy).

## What this proves

C4a proved prefix strip works for a shared tool list (all clients see the same tools). C4b extends that: per-user tool lists are possible via separate listener configs, and documents two key behavioral findings discovered during the run.

## Architecture

```
alice -> :10001 -> mcp_filter -> mcp_router(server1 only) -> backend-a (server1)

bob   -> :10002 -> mcp_filter -> mcp_router(server1 + server2) -> backend-a (server1)
                                                               -> backend-b (server2)
```

Two listeners in one `envoy.yaml`, each configured with a different `mcp_router` server list.

## Key findings

### Finding 1: one-backend mcp_router does not add a prefix

With one server configured, `mcp_router` exposes tools under their natural names (`tool1`, `tool2`, `tool3`). The `serverName__` prefix is only added when there are multiple servers to disambiguate.

| Config | tools/list result | tools/call syntax |
|---|---|---|
| one backend (alice) | `tool1, tool2, tool3` | `tool1` |
| two servers (bob) | `server1__tool1, server2__tool1, ...` | `server1__tool1` |

### Finding 2: one-backend mcp_router is a transparent pass-through

One-backend `mcp_router` does **not** validate tool names. Any `tools/call` — regardless of prefix — is forwarded to the one configured server with the full name intact. Calling `server2__tool1` on alice's listener routes to server1 and returns `"server1 ran server2__tool1"`.

Tool name isolation requires `ext_authz` (C2) or `MCPVirtualServer` — the router config alone is not enough.

## Practical limitation of the two-listener approach

The same underlying tool has different names on each endpoint. Alice calls `tool1`; bob calls `server1__tool1` for the same tool. This naming inconsistency is the main reason the two-listener approach is not production-viable as a per-user solution.

`MCPVirtualServer` (Kuadrant) solves this by applying per-user filtering at the aggregation layer — all clients see consistent prefixed names and the gateway enforces the per-user subset.

## How to run

```bash
docker compose up -d
./smoke.sh
docker compose down
```

## Tests

| Test | What it checks | Result |
|---|---|---|
| alice `tools/list` | one-backend config: no prefix | `tool1, tool2, tool3` |
| bob `tools/list` | two-backend config: prefixed | `server1__tool1, server2__tool1, ...` |
| alice calls `tool1` | routes to server1 correctly | `"server1 ran tool1"` |
| alice calls `server2__tool1` | observation: passes through to server1 (no validation) | `"server1 ran server2__tool1"` |
| bob calls `server2__tool1` | prefix stripped, routed to server2 | `"server2 ran tool1"` |
