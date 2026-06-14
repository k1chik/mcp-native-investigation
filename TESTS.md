# Tests

A tracker for every test in this investigation. Status is updated as work lands.

| Status | Meaning |
|---|---|
| `done` | ran, result recorded |
| `pending` | not yet run |
| `deferred` | needs the full Kuadrant/Istio stack - out of scope for the bare-Envoy spine |

---

## Phase overview

| Phase | Goal                                                                                                                                                                                                                                          | Output                                      | Status    |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- | --------- |
| 1     | Map each ext-proc job to a native Envoy capability; identify the residual                                                                                                                                                                     | Job-to-capability map                       | `done`    |
| 2     | Build the side-by-side prototype; run all capability and operational tests                                                                                                                                                                    | Prototype + measured results                | `done`    |
| 3     | Write the target architecture and migration plan; document the Istio upgrade path (1.26 to 1.29+) and the deployment migration for existing users (prefix rename is breaking - `server1_toolname` to `server1__toolname` - not a config flag) | PR to `Kuadrant/mcp-gateway` `docs/design/` | `pending` |

---

## Lanes

Each test runs in one or more lanes. A lane is a self-contained `docker-compose` stack with its own Envoy config and backends.

| Lane             | What runs                                                              | Used by              |
| ---------------- | ---------------------------------------------------------------------- | -------------------- |
| `c1-c3-c4a/`     | Envoy v1.38.0: `mcp_filter` → `mcp_router`, no ext-proc                | C1, C3, C4a          |
| `c2/`            | Same + `ext_authz` (OPA) in the chain                                  | C2                   |
| `c4b/`           | native-lane variant with per-user tool list (two listeners)            | C4b                  |
| `v1-v3-v4/`      | Same Envoy + 2 backends; controllable init delay; k6 for latency       | V1, V3, V4           |
| `v2/`            | Same Envoy + backend-a pushes `list_changed` every 2s                  | V2                   |
| `v6/`            | mcp-gateway v0.7.0 broker + 2 backends with distinct credentials       | V6                   |
| `c5/`            | Envoy `mcp_filter` → `ext_authz` → `router` → single backend           | C5                   |
| `kuadrant-stack` | kind + Istio + Gateway API + full Kuadrant stack                       | V5 — stays broker-only; virtual-server filtering requires the `MCPVirtualServer` CRD which only runs on the full Kuadrant stack |

---

## Capability checks

*Can native Envoy do the job at all?* Each check runs on bare Envoy `v1.38.0` with no Istio.

| ID  | What it proves                                                                                                      | Lane              | Status    |
| --- | ------------------------------------------------------------------------------------------------------------------- | ----------------- | --------- |
| C1  | `mcp_filter` parses MCP and populates Envoy dynamic metadata                                                        | native-lane       | `done`    |
| C2  | An external authorizer reads `envoy.filters.http.mcp` metadata and allows/denies by tool name                       | native-lane-authz | `done`    |
| C3  | `mcp_router` fans out and prefix-merges `tools/list` across two backends                                            | native-lane       | `done`    |
| C4a | `mcp_router` strips the tool-name prefix on `tools/call` — one prefix list shared by all clients                    | native-lane / v4  | `done`    |
| C4b | Same prefix strip, but the allowed-tool list differs per user (requires `MCPVirtualServer`-style per-client config) | c4b/              | `done`    |
| C5  | Native `mcp_filter` + `AuthPolicy` as a complete standalone MCP gateway for a **single** backend — no mcp-gateway needed (mentor feedback: single-server MCP use case) | c5/               | `done`    |

---

## Operational checks

*Does native Envoy behave well enough in real use?* Each check runs side-by-side (native lane vs broker lane) on the same backends.

**Acceptance bar (mentor guidance, Q4).** Lower latency on `tools/call` is the primary goal - but not at the cost of two specific operational regressions:

- If replacing `ext-proc` means every `tools/list` fans out live to all backends with no caching, that is a net negative (V1, V2).
- If a slow backend blocks every client at `initialize`, that is a net negative (V3).

V4 measures the latency win. V1 and V3 measure the regression cost. All three must be characterized before Phase 3 can make its recommendation. The expected shape of the answer is a hybrid: native Envoy handles `tools/call` routing; the broker keeps caching, notification handling, and auth.

| ID  | What it measures                                                                                                                                                                                                                                                       | Lanes                      | Claim | CONNLINK-1026                                    | Status                                                                                                |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- | ----- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| V1  | Caching: upstream `tools/list` hits per backend over M calls                                                                                                                                                                                                           | native-lane                | yes   | Jonh Wendell: no-cache finding                   | `done`                                                                                                |
| V2  | SSE relay: does native Envoy relay `tools/list_changed` to clients or subscribe to backends?                                                                                                                                                                           | native-lane                | yes   | Craig Brookes concern #3: fanout storm           | `done`                                                                                                |
| V3  | Eager-vs-lazy: client `initialize` latency with one slow backend (lazy init was a deliberate design choice - see `initializeMCPSeverSession` in `internal/mcp-router/request_handlers.go:665` - characterize the tradeoff before recommending native's eager behavior) | native-lane                | yes   | Craig Brookes concern #4; David Martin Blocker 2 | `done`                                                                                                |
| V4  | Hot-path `tools/call` p50/p95 latency                                                                                                                                                                                                                                  | native-lane                | yes   | David Martin Blocker 1: native wins the hot path | `done`                                                                                                |
| V5  | Virtual-server filtering: tool subset per tenant (`MCPVirtualServer`)                                                                                                                                                                                                  | broker (+ native negative) | no    | Craig Brookes: virtual-server filtering          | `done` — see [tests/operational/v5/README.md](tests/operational/v5/README.md) |
| V6  | Per-backend auth: distinct credentials per backend                                                                                                                                                                                                                     | broker-lane                | no    | Craig Brookes concern #5: per-backend auth       | `done`                                                                                                |
| V7  | Prefix migration: `server1_tool` vs `server1__tool` (delimiter change — breaking rename)                                                                                                                                                                               | native-lane                | yes   | Discovered in analysis                           | `done - documented analysis`                                                                          |

---

## Scope boundary

```
Bare-Envoy spine (runs on a laptop):   C1, C2, C3, C4a, C4b   [all done]
                                        C5                       [done]
                                        V1, V2, V3, V4, V6      [all done]
                                        V7 (documented analysis) [done]
                                        V5 [done — no native equivalent; see tests/operational/v5/README.md]
Needs full Kuadrant stack              V5 broker positive (MCPVirtualServer CRD — kind + Istio + Kuadrant controller)
(kind + Istio + Gateway API):          C5 with literal AuthPolicy (OPA proxy used locally)
```

V5 and V6 are deliberately deferred, not forgotten. Their negative (native cannot do them)
is established from code — the deferred tests would prove the broker positive.

---

## Step 0: Environment setup

| Task | Status |
|---|---|
| Run `create-env.sh` - clone sources, pull images, smoke-check | `done` |

---

## Phase 1: ext-proc job mapping

*What does `ext-proc` do today, and which of those jobs can the envoy's native mcp-filter chain take over?* This is what Phase 1 maps.

`Kuadrant/mcp-gateway`'s external processor (`internal/mcp-router/`) handles eight responsibilities. The column "native covers it?" is the claim each test settles.

| Job | What `ext-proc` does today                                 | Claim                                                                                                                                   | Mapped to    | Status                 |
| --- | ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------ | ---------------------- |
| 1   | Parse JSON-RPC request body                                | Yes                                                                                                                                     | C1           | `done`                 |
| 2   | Inject headers/metadata (`x-mcp-method`, `x-mcp-toolname`) | Yes - as dynamic metadata; no header conversion needed                                                                                  | C1 + C2      | `done`                 |
| 3   | Rewrite body (strip tool-name prefix)                      | Partial - works for shared lists (C4a); per-user via separate listener configs but no call isolation and inconsistent tool naming (C4b) | C4a + C4b    | `done`                 |
| 4   | Route to the right backend (fan-out + prefix-merge)        | Yes                                                                                                                                     | C3           | `done`                 |
| 5   | JWT-based session management                               | No - stays custom (native session ID is stateless base64 composite; JWT mint/TTL/signing stays broker-side)                             | stays custom | `done` — no native equivalent |
| 6   | Start backend sessions (lazy init)                         | Partial - native is eager and blocks on the slowest backend (bounded by connect_timeout ~5s then degrades; dead backend does not block) | V3           | `done`                 |
| 7   | Route elicitation responses                                | No - stays custom (no mid-stream JSON-RPC ID rewrite; no elicitation concept in native router)                                          | stays custom | `done` — no native equivalent |
| 8   | Handle tool annotations                                    | Yes - native preserves tool annotations transparently                                                                                   | V4           | `done`                 |

Jobs 1-4 and 8 are the "can native do it?" question. Jobs 5-7 stay custom - the tests document how and at what cost.

---

## Critical questions from #809

Five questions [issue #809](https://github.com/Kuadrant/mcp-gateway/issues/809) raised. Each is settled by a test or a documented answer.

| Q   | Question                                                            | Settled by                                                           | Status    |
| --- | ------------------------------------------------------------------- | -------------------------------------------------------------------- | --------- |
| Q1  | Can the native filter modify the request body (strip prefixes)?     | C4a, C4b                                                             | `done`    |
| Q2  | Can Authorino read native metadata directly - no header conversion? | C2                                                                   | `done`    |
| Q3  | How do native sessions compare to the JWT model?                    | Native uses stateless base64 composite session ID (packs backend sessions into the token); forces eager init (Blocker 2); JWT lifecycle, TTL, and signing stay custom in the broker | `done` |
| Q4  | Minimum Istio version for the native filter?                        | documented - Envoy 1.37+ needs Istio 1.29+; production is below that | `done`    |
| Q5  | Does native aggregation replace the broker's federation?            | Only the mechanical fan-out + prefix-merge (C3). Cache, targeted `list_changed` refresh, virtual-server filtering all stay broker-owned (V1, V2, V5) | `done` |

---

## My validation results

| Feature | MCP Gateway (Router/Broker) | Envoy Native | Assessment | My Envoy Native | My Assessment | What is Different |
| ------- | --------------------------- | ------------ | ---------- | --------------- | ------------- | ----------------- |
| **JSON-RPC parsing & validation** | Router ext_proc parses body | `envoy.filters.http.mcp` filter - full JSON-RPC 2.0 parsing with field extraction | Full overlap. Envoy's implementation is native C++ (no ext_proc latency), with fuzz testing | `mcp` filter extracts `method`, `id`, `jsonrpc`, `is_mcp_request`, `params.name` into `native_meta`. `params.arguments` is silently dropped from dynamic metadata. | Partial overlap | `params.arguments` is not extracted into dynamic metadata — any filter or authorizer needing argument values cannot get them from `native_meta`; requires ext_proc or raw body inspection |
| **Tool/prompt/resource aggregation** | Broker aggregates tools/list from upstreams | `envoy.filters.http.mcp_router` - aggregates tools, resources, prompts, completions from multiple backends | Full overlap. Envoy covers tools, resources (list, read, subscribe, unsubscribe, templates), prompts, completion, logging, sampling | Fan-out confirmed for `resources/list`, `resources/templates/list`, `prompts/list` — both backends hit, results merged, backend hit counts verified via `/__stats`. Single-backend routing confirmed for `resources/read`, `resources/subscribe`, `resources/unsubscribe`, `prompts/get`, `completion/complete`. `logging/setLevel` broadcast to all backends. `sampling/createMessage` tested in three ways: (1) POST client→gateway: rejected with "Invalid or missing MCP request"; (2) GET client→gateway: 405 Method Not Allowed — no client-facing SSE channel; (3) backend-initiated: `mcp_router` never opened a GET SSE connection to either backend (`sse_get_connections_total: 0` on both after `initialize`). The investigation's own PRIMER.md states "native doesn't" relay `tools/list_changed" — the same channel sampling requires. Original "Full overlap" claim contradicts the investigation's own PRIMER and was not empirically verified. | Partial overlap — all POST-based aggregation and routing works; sampling is not supported in any direction and is contradicted by the investigation's own PRIMER | Two prefixing schemes in use: tools and prompts use `server1__name` (double underscore); resources use `server1+scheme://path` (server name prepended to URI scheme). `sampling/createMessage` is fully unsupported: GET 405 on gateway (no client receive channel), zero backend GET SSE connections opened by `mcp_router` (no backend send channel). Original "Full overlap" contradicts the PRIMER written by the same investigator. |
| **Name prefixing** | Broker adds prefixes, router strips them | MCP router handles prefixing/stripping natively (via `name` field in `McpBackend`) | Full overlap | Confirmed double-underscore delimiter: `server1__tool1`, `server2__tool1`. Prefix correctly stripped on `tools/call` — backend received plain `tool1`. Also confirmed for prompts (`server1__prompt1`) and resources (URI scheme prefix `server1+mock://...`). | Full overlap | None observed for tools and prompts. Resources use a different scheme: URI scheme prefixing (`server1+scheme://path`) rather than name prefixing — this is intentional to preserve URI structure |
| **Routing tool calls** | Router sets `:authority` header via ext_proc | MCP router routes directly to backend clusters - no header rewriting needed | Full overlap and simpler - no ext_proc hop required | `mcp_router` routes correctly by prefix on `tools/call` — `server1__tool3` routed to backend-a, `server2__tool1` routed to backend-b, backend hit counts confirmed. Attempted `dynamic_metadata` route matching on `envoy.filters.http.mcp.method` in route config — all requests fell through to default route regardless of method. | Full overlap for `mcp_router` path | `dynamic_metadata` route matchers in the route config cannot be used to route on MCP method — routing decision is committed during `decodeHeaders` before the body is parsed; `mcp_router` must own the routing decision, not the route config. Unknown server prefix (`server3__tool1`) returns a clean error with no backend hit. |
| **Session management** | Router manages gateway-to-backend session mapping in Redis/memory | MCP router manages sessions natively with session ID encoding/decoding | Full overlap - Envoy encodes backend info in the session ID itself | Not tested. The investigation's own `curr-state.md` states "Jobs 5, 7: stay custom — no native equivalent (JWT session management)" — directly contradicting the Full overlap claim in this table. | Contradicted by own investigation docs — not tested empirically | `curr-state.md` (same investigation) explicitly says JWT session management stays custom, which contradicts the Full overlap claim here. |
| **SSE streaming** | Broker handles SSE notifications | MCP router has full SSE support with incremental parsing, event classification (notifications vs responses vs server requests), mixed JSON+SSE aggregation | Full overlap | GET request to gateway returns `405 Method Not Allowed` — no client-facing SSE channel exists. `mcp_router` opened zero GET SSE connections to either backend after `initialize` and `tools/list` (`sse_get_connections_total: 0` on both backends confirmed via `/__stats`). `/__trigger_sampling` on backend returned `pushed: 0, open_connections: 0`. The investigation's own PRIMER explicitly states "native doesn't" relay `tools/list_changed` notifications. | Not full overlap — SSE streaming not supported in either direction | GET returns 405 on gateway — clients cannot receive any server-initiated messages. `mcp_router` never opens GET SSE connections to backends — backends have no channel to push notifications. Directly contradicts "Full overlap" and is confirmed by the investigation's own PRIMER. |
| **MCP method support** | initialize, tools/list, tools/call, prompts/list, prompts/get, notifications | initialize, ping, tools/list, tools/call, resources/list, resources/read, resources/subscribe, resources/unsubscribe, resources/templates/list, prompts/list, prompts/get, completion/complete, logging/setLevel, sampling/createMessage, notifications (fanout) | Envoy exceeds - supports more MCP methods natively | All POST-based methods tested and confirmed working: `tools/*`, `resources/*`, `prompts/*`, `completion/complete`, `logging/setLevel`. `sampling/createMessage` rejected client→gateway. Notifications (fanout to clients) cannot work — GET 405 on gateway means clients can never receive server-pushed events. | Mostly correct for POST methods — `sampling/createMessage` and notification fanout to clients are not supported | `sampling/createMessage` listed as supported but is non-functional in any direction. "notifications (fanout)" implies pushing to clients — impossible with no GET SSE channel. |
| **Policy enforcement (RBAC)** | Via Kuadrant AuthPolicy / ext_authz integration | MCP filter extracts attributes to dynamic metadata; standard RBAC or ext_authz filters consume them | Full overlap - native filter chain integration is more efficient | Not tested by us. Original investigation C2 (PASS) confirmed OPA reads `envoy.filters.http.mcp` metadata and allows/denies by tool name without header conversion. Consistent with our C1 findings: metadata shape and field names confirmed. | Accepted — C2 PASS in original investigation is reliable and consistent with our metadata findings | None — C2 confirms the claim. Note: only `params.name` (tool name) is in metadata, not `params.arguments` — argument-based policy still requires ext_proc (see row 1). |
| **Observability** | OpenTelemetry via OTLP + metrics | MCP filter supports W3C trace context propagation (`traceparent`, `tracestate`, `baggage`), plus statistics counters, access log metadata | Full overlap with different approach - Envoy propagates W3C trace context from MCP body to HTTP headers | Not fully tested. Stats counters confirmed working from original C1 smoke results: `http.mcp_gw.mcp.invalid_json`, `mcp.requests_rejected`, `mcp.body_too_large` all present and increment correctly. W3C trace propagation not tested. | Partially supported by evidence — stats counters confirmed; W3C trace propagation and access log metadata not verified by us | Not fully tested |
| **Session identity validation** | JWT-based gateway session IDs | MCP router supports `SessionIdentity` with header or dynamic metadata extraction, with ENFORCE or DISABLED modes | Full overlap | Not tested | Not tested | Not tested |
| **REST-to-MCP bridging** | Not implemented | `envoy.filters.http.mcp_json_rest_bridge` transcodes MCP JSON-RPC to/from REST | Envoy-only feature | Not tested — requires `envoy.filters.http.mcp_json_rest_bridge` filter which is not in our current config | Not tested | Not tested |
| **Multi-cluster support** | Via HTTPRoutes + ext_proc routing | `envoy.clusters.mcp_multi_cluster` - aggregates multiple clusters for MCP | Envoy-only feature | Not tested — requires `envoy.clusters.mcp_multi_cluster` which is not in our current config | Not tested | Not tested |
| **Protocol version support** | Supports MCP spec versions | Supports 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25 with negotiation | Full overlap | Partially tested — sent `protocolVersion: 2025-03-26` in `initialize`; gateway responded with `2025-06-18` (version negotiation confirmed). Other versions not tested. | Partially tested — negotiation observed; full version matrix not verified | Version negotiation works — gateway upgraded `2025-03-26` to `2025-06-18` in the `initialize` response |
