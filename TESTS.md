# Tests

A tracker for every test in this investigation. Status is updated as work lands.

| Status | Meaning |
|---|---|
| `done` | ran, result recorded |
| `pending` | not yet run |
| `deferred` | needs the full Kuadrant/Istio stack - out of scope for the bare-Envoy spine |

---

## Phase overview

| Phase | Goal                                                                                                                                                                                                                                          | Output                                      |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| 1     | Map each ext-proc job to a native Envoy capability; identify the residual                                                                                                                                                                     | Design notes                                |
| 2     | Build the side-by-side prototype; run all capability and operational tests                                                                                                                                                                    | Prototype + measured results                |
| 3     | Write the target architecture and migration plan; document the Istio upgrade path (1.26 to 1.29+) and the deployment migration for existing users (prefix rename is breaking - `server1_toolname` to `server1__toolname` - not a config flag) | PR to `Kuadrant/mcp-gateway` `docs/design/` |

---

## Step 0: Environment setup

| Task | Status |
|---|---|
| Run `create-env.sh` - clone sources, pull images, smoke-check | `done` |

---

## Phase 1: ext-proc job mapping

*What does `ext-proc` do today, and which of those jobs can the native filter chain take over?* This is what Phase 1 maps.

`Kuadrant/mcp-gateway`'s external processor (`internal/mcp-router/`, ~2,500 lines of Go) handles eight responsibilities. The column "native covers it?" is the claim each test settles.

| Job | What `ext-proc` does today                                 | Native covers it?                                                   | Mapped to            | Status    |
| --- | ---------------------------------------------------------- | ------------------------------------------------------------------- | -------------------- | --------- |
| 1   | Parse JSON-RPC request body                                | Yes                                                                 | C1                   | `done`    |
| 2   | Inject headers/metadata (`x-mcp-method`, `x-mcp-toolname`) | Yes - as dynamic metadata; no header conversion needed              | C1 + C2              | `pending` |
| 3   | Rewrite body (strip tool-name prefix)                      | Yes - static and user-specific lists                                | C4a + C4b            | `done`    |
| 4   | Route to the right backend (fan-out + prefix-merge)        | Yes                                                                 | C3                   | `done`    |
| 5   | JWT-based session management                               | No - stays custom (native session ID is stateless base64 composite) | characterization     | `pending` |
| 6   | Start backend sessions (lazy init)                         | Partial - native is eager and blocks on the slowest backend         | V3                   | `pending` |
| 7   | Route elicitation responses                                | No - stays custom (no mid-stream JSON-RPC ID rewrite)               | characterization     | `pending` |
| 8   | Handle tool annotations                                    | Yes - native preserves them                                         | V4 (fair comparison) | `pending` |

Jobs 1-4 and 8 are the "can native do it?" question. Jobs 5-7 are expected to stay custom - the tests characterize how and at what cost.

---

## Critical questions from #809

Five questions [issue #809](https://github.com/Kuadrant/mcp-gateway/issues/809) raised. Each is settled by a test or a documented answer.

| Q | Question | Settled by | Status |
|---|---|---|---|
| Q1 | Can the native filter modify the request body (strip prefixes)? | C4a, C4b | `pending` |
| Q2 | Can Authorino read native metadata directly - no header conversion? | C2 | `pending` |
| Q3 | How do native sessions compare to the JWT model? | job 5 characterization | `pending` |
| Q4 | Minimum Istio version for the native filter? | documented - Envoy 1.37+ needs Istio 1.29+; production is below that | `done` |
| Q5 | Does native aggregation replace the broker's federation? | C3, V1, V2 | `pending` |

---

## Capability checks

*Can native Envoy do the job at all?* Each check runs on bare Envoy `v1.38.0` with no Istio.

| ID | What it proves | Lane | Status |
|---|---|---|---|
| C1 | `mcp_filter` parses MCP and populates Envoy dynamic metadata | native-lane | `done` |
| C2 | An external authorizer reads `envoy.filters.http.mcp` metadata and allows/denies by tool name | native-lane-authz | `pending` |
| C3 | `mcp_router` fans out and prefix-merges `tools/list` across two backends | native-lane | `done` |
| C4a | `mcp_router` rewrites the body to strip the tool prefix on `tools/call` for a static/shared tool list | native-lane / v4-fair | `done` |
| C4b | Same body rewrite for a user-specific tool list | c4b/ | `pending` |

---

## Operational checks

*Does native Envoy behave well enough in real use?* Each check runs side-by-side (native lane vs broker lane) on the same backends.

**Acceptance bar (mentor guidance, Q4).** Lower latency on `tools/call` is the primary goal - but not at the cost of two specific operational regressions:

- If replacing `ext-proc` means every `tools/list` fans out live to all backends with no caching, that is a net negative (V1, V2).
- If a slow backend blocks every client at `initialize`, that is a net negative (V3).

V4 measures the latency win. V1 and V3 measure the regression cost. All three must be characterized before Phase 3 can make its recommendation. The expected shape of the answer is a hybrid: native Envoy handles `tools/call` routing; the broker keeps caching, notification handling, and auth.

| ID  | What it measures                                                               | Lanes                      | Bare-Envoy? | Status     |
| --- | ------------------------------------------------------------------------------ | -------------------------- | ----------- | ---------- |
| V1  | Caching: upstream `tools/list` hits per backend over M calls                   | native vs broker           | yes         | `pending`  |
| V2  | Fanout storm: aggregate upstream RPS under `tools/list_changed` at frequency f | native vs broker           | yes         | `pending`  |
| V3  | Eager-vs-lazy: client `initialize` latency with one slow backend (lazy init was a deliberate design choice - see `initializeMCPSeverSession` in `internal/mcp-router/request_handlers.go:665` - characterize the tradeoff before recommending native's eager behavior) | native vs broker           | yes         | `pending`  |
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
