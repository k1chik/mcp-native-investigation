# V5 — Virtual-server filtering

**Status: deferred — needs the full Kuadrant/Istio stack**

## What this checks

| ID | What it measures | CONNLINK-1026 |
|----|-----------------|---------------|
| V5 | Broker filters the aggregated tool list to a per-tenant subset when `X-Mcp-Virtualserver` header is present. Native `mcp_router` has no equivalent — all clients on the same listener see the full list. | Craig Brookes: virtual-server filtering |

## Why native cannot do this

`mcp_router` aggregates tool lists from all backends into one response. There is no
per-client or per-header filtering concept — the merged list goes to every caller
equally. The only native workaround is separate listener configs per user group (tested
in C4b), but that causes naming inconsistency (tools have different names on different
listeners) and requires static config per user group rather than dynamic per-request
filtering.

## Why deferred

`MCPVirtualServer` is a Kubernetes CRD. Proving the broker positive requires:
- A running kind cluster
- Istio 1.29+ (to get Envoy 1.37+ in the mesh)
- Kuadrant mcp-gateway deployed with the controller watching CRDs
- An `MCPVirtualServer` object applied with a tool subset defined

This is out of scope for the bare-Envoy + standalone-broker spine this repo runs on.
The deferred test would prove the broker positive (the mechanism is established from
code: `GetVirtualSeverByHeader` in `broker.go` + `applyVirtualServerFilter` in
`filtered_tools_handler.go`).

## What is established without the full stack

**Native negative** (proven in this investigation):
- C4b shows the two-listener workaround and its naming inconsistency limitation
- `mcp_router` has no virtual-server concept in any config field or proto definition

**Broker positive** (from code, not live run in this repo):
- `X-Mcp-Virtualserver: <namespace>/<name>` header → broker looks up the matching
  `MCPVirtualServer` object → filters tool list to the configured subset
- Without the header → full aggregated list returned to all clients

## Conclusion

For multi-tenant deployments where different clients need different tool subsets,
the broker's `MCPVirtualServer` is required. Native `mcp_router` cannot replicate
this without static per-listener config, which does not scale to dynamic per-user
filtering.
