# C1, C3, C4a - Native Envoy MCP parse, fan-out, and routing

Bare Envoy `v1.38.0` with no broker, no ext-proc, and no Istio. Envoy's own
`mcp` and `mcp_router` HTTP filters handle all three jobs.

## What this lane checks

| ID | What it checks |
|---|---|
| C1 | `mcp` filter parses the JSON-RPC body and populates Envoy dynamic metadata. Negative: a malformed body increments `mcp.invalid_json`, confirming the parser ran. |
| C3 | `mcp_router` fans out `tools/list` to both backends, merges the results, and prefixes each tool with its server name so colliding names across backends do not clash. |
| C4a | `tools/call` with a prefixed tool name (`server1__tool1`) is stripped and routed to the correct backend. All 5 tools across both backends are exercised. |

## Prerequisites

- `docker`
- `jq`

No other tools needed. The mock backends run inside the compose network.

## How to run

```bash
docker compose up -d
./smoke.sh
docker compose down
```

Run from this directory. `smoke.sh` exits `0` on pass, `1` on failure and prints
a per-check verdict.

To point at a different host:

```bash
GW=http://host:10000 ./smoke.sh
```

## Expected output

```
== initialize (through the gateway) ==
{"name":"envoy-mcp-gateway","version":"1.0.0"}

== tools/list - expect BOTH backends, prefixed (C3) ==
  tools: server1__tool1, server1__tool2, server1__tool3, server2__tool1, server2__tool2

== C1 negative - malformed body must increment mcp.invalid_json ==
  C1 negative PASS - invalid_json counter went 0 -> 1 (parser ran)

== C4a - tools/call for every tool on both backends ==
  server1__tool1 -> "server1 ran tool1" ✓
  server1__tool2 -> "server1 ran tool2" ✓
  server1__tool3 -> "server1 ran tool3" ✓
  server2__tool1 -> "server2 ran tool1" ✓
  server2__tool2 -> "server2 ran tool2" ✓

== verdict ==
  C3  PASS - both backends aggregated, colliding tool names disambiguated by prefix
  C4a PASS - all 5 tools routed and prefix-stripped correctly
  C1  PASS - mcp filter parsed requests (negative test confirmed parser active)
  OVERALL PASS
```

## What the setup looks like

```
smoke.sh (curl)
    -> Envoy :10000
        mcp filter        (parse JSON-RPC body -> dynamic metadata)
        mcp_router        (fan-out, prefix-merge, terminal)
            -> backend-a (server1) :9001  - 3 tools
            -> backend-b (server2) :9002  - 2 tools
Envoy admin :9901  (stats, used by C1 negative check)
```

The `mcp_router` filter is terminal: it replaces `envoy.filters.http.router`
entirely. The `route_config` in `envoy.yaml` is a required placeholder but
`mcp_router` decides the actual backend.

The prefix delimiter is a hardcoded double underscore `__`. `server1__tool1`,
not `server1_tool1`.
