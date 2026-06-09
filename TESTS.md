# Tests

A tracker for every test in this investigation. Status is updated as work lands.

| Status | Meaning |
|---|---|
| `done` | ran, result recorded |
| `pending` | not yet run |
| `deferred` | needs the full Kuadrant/Istio stack — out of scope for the bare-Envoy spine |

---

## Phase overview

| Phase | Goal | Output |
|---|---|---|
| 1 | Map each ext-proc job to a native Envoy capability; identify the residual | Design notes |
| 2 | Build the side-by-side prototype; run all capability and operational tests | Prototype + measured results |
| 3 | Write the target architecture and migration plan | PR to `Kuadrant/mcp-gateway` `docs/design/` |

---

## Step 0: Environment setup

| Task | Status |
|---|---|
| Run `create-env.sh` — clone sources, pull images, smoke-check | `done` |

---

## Capability checks

*Can native Envoy do the job at all?* Each check runs on bare Envoy `v1.38.0` with no Istio.

| ID | What it proves | Lane | Status |
|---|---|---|---|
| C1 | `mcp_filter` parses MCP and populates Envoy dynamic metadata | native-lane | `pending` |
| C2 | An external authorizer reads `envoy.filters.http.mcp` metadata and allows/denies by tool name | native-lane-authz | `pending` |
| C3 | `mcp_router` fans out and prefix-merges `tools/list` across two backends | native-lane | `pending` |
| C4a | `mcp_router` rewrites the body to strip the tool prefix on `tools/call` for a static/shared tool list | native-lane | `pending` |
| C4b | Same body rewrite for a user-specific tool list | c4b | `pending` |

---

## Operational checks

*Does native Envoy behave well enough in real use?* Each check runs side-by-side (native lane vs broker lane) on the same backends.

| ID  | What it measures                                                               | Lanes                      | Bare-Envoy? | Status     |
| --- | ------------------------------------------------------------------------------ | -------------------------- | ----------- | ---------- |
| V1  | Caching: upstream `tools/list` hits per backend over M calls                   | native vs broker           | yes         | `pending`  |
| V2  | Fanout storm: aggregate upstream RPS under `tools/list_changed` at frequency f | native vs broker           | yes         | `pending`  |
| V3  | Eager-vs-lazy: client `initialize` latency with one slow backend               | native vs broker           | yes         | `pending`  |
| V4  | Hot-path `tools/call` p50/p99 latency                                          | native vs broker           | yes         | `pending`  |
| V5  | Virtual-server filtering: tool subset per tenant (`MCPVirtualServer`)          | broker (+ native negative) | no          | `deferred` |
| V6  | Per-backend auth: distinct credentials per backend                             | broker (+ native negative) | no          | `deferred` |
| V7  | Prefix migration: `server1_tool` vs `server1__tool` (delimiter change)         | native-lane                | yes         | `pending`  |

---

## Scope boundary

```
Bare-Envoy spine (runs on a laptop):   C1, C2, C3, C4a, C4b, V1, V2, V3, V4, V7
Needs full Kuadrant stack              V5 (MCPVirtualServer CRD),
(kind + Istio + Gateway API):          V6 (AuthPolicy + HTTPRoute)
```

V5 and V6 are documented from code citations. They are deliberately deferred, not forgotten.
