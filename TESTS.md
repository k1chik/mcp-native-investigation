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

## Second run: validation results

| Feature | What we found | vs original claim |
| ------- | ------------- | ----------------- |
| JSON-RPC parsing & validation | `mcp_filter` extracts `method`, `id`, `jsonrpc`, `is_mcp_request`, `params.name`. `params.arguments` is silently dropped from dynamic metadata. | Partial — arguments not in metadata |
| Tool/prompt/resource aggregation | POST-based fan-out confirmed for `tools/*`, `resources/*`, `prompts/*`, `completion/complete`, `logging/setLevel`. `sampling/createMessage` tested three ways: POST client→gateway rejected ("Invalid or missing MCP request"); GET client→gateway returned 405; `mcp_router` never opened a GET SSE connection to either backend (`sse_get_connections_total: 0`). | Partial — all POST methods work; sampling not supported in any direction |
| Name prefixing | Double-underscore delimiter confirmed for tools (`server1__tool1`) and prompts (`server1__prompt1`). Resources use URI scheme prefixing (`server1+scheme://path`) rather than name prefixing — intentional to preserve URI structure. Prefix correctly stripped on `tools/call`. | Full overlap for tools and prompts. Resources use a different scheme by design. |
| Routing tool calls | Routing correct by prefix — backend hit counts verified. `dynamic_metadata` route matchers on `envoy.filters.http.mcp.method` do not work; all requests fell through to the default route. Routing must go through `mcp_router`, not the route config. Unknown prefix returns a clean error with no backend hit. | Full overlap via `mcp_router`. Route config matchers on MCP method are not usable. |
| Session management | Not tested. Own investigation docs explicitly state JWT session management stays custom — this contradicts the original "full overlap" claim. | Contradicted by own docs |
| SSE streaming | GET to gateway returns 405. `mcp_router` opened zero GET connections to either backend. `/__trigger_sampling` on backend returned `pushed: 0, open_connections: 0`. | Not supported in either direction |
| MCP method support | All POST-based methods confirmed working. `sampling/createMessage` non-functional client-side. Notification fanout to clients impossible — no GET SSE channel on the gateway. | Partial — POST methods work; sampling and notification fanout do not |
| Policy enforcement (RBAC) | C2 result accepted. `params.name` available for policy decisions; `params.arguments` is not. Argument-based rules require a separate step. | Confirmed, with the arguments gap noted |
| Observability | Stats counters confirmed (`invalid_json`, `requests_rejected`, `body_too_large` all increment correctly). W3C trace propagation not tested. | Partial |
| Protocol version | Sent `2025-03-26` in `initialize`, received `2025-06-18` — negotiation confirmed. Full version matrix not tested. | Partial — negotiation works |

Session identity validation, REST-to-MCP bridging, and multi-cluster support were not tested — they require filter configs not in scope for this investigation.
