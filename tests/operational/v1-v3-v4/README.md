# V1, V3, V4 — Operational checks on the native Envoy lane

Three operational checks that measure properties of Envoy's `mcp_filter` + `mcp_router` chain
that the capability checks (C1–C4) do not cover. All three run against the same two-backend
setup — no broker, no ext-proc, no Istio.

## What this lane checks

| ID | What it measures | CONNLINK-1026 |
|----|-----------------|---------------|
| V1 | **No tool-list cache** — every `tools/list` fans out live to ALL backends (M=10 client calls → 10 hits per backend) | Jonh Wendell's no-cache finding |
| V3 | **Eager init / head-of-line blocking** — one slow backend delays every client's `initialize`; delay 3s → client blocked ~3s | Craig Brookes concern #4; David Martin Blocker 2 |
| V4 | **`tools/call` hot-path latency** — in-process routing (no gRPC hop); measured p50/p95 under 10 VUs | David Martin Blocker 1 (native wins the hot path) |

## Prerequisites

- `docker`
- `python3`
- `k6` (for V4 only — `brew install k6`; V1 and V3 still run without it)

## How to run

```bash
docker compose up -d
./run-v-tests.sh
docker compose down
```

From this directory. The script exits `0` on all pass, `1` on any failure.

## Expected output

```
########  V1 — no cache: every tools/list fans out to all backends  ########
  10 client tools/list -> backend-a=10  backend-b=10  (expect both >= 10)
  V1 PASS — no cache confirmed: each client tools/list fanned out to BOTH backends

########  V3 — eager init: slow backend blocks client initialize  ########
  baseline initialize (no delay): ~25ms
  initialize with backend-b delayed 3s: ~3100ms
  V3 PASS — eager init confirmed: slow backend blocked client initialize

########  V4 — tools/call hot-path latency (10 VUs, 15s, k6)  ########
  p50=~1.3ms  p90=~2.5ms  p95=~2.9ms  rps=~5700
  V4 PASS — k6 thresholds met

ALL V-TESTS PASS (V1, V3, V4)
```

## Key findings

**V1 — no cache.** `mcp_router` has no tool-list cache (`handleToolsList` → `initializeFanout`
directly, no cache lookup). Every client `tools/list` is a live fan-out to every backend.
With N backends and M client list calls, the backend hit count is M×N — cost scales linearly
with both.

**V3 — eager init is bounded.** `mcp_router` contacts all backends eagerly at `initialize`
(`handleInitialize` → `initializeFanout` over all configured backends, waits for all).
A 3s backend delay blocks the client ~3s. Important nuance: the block is bounded by
`connect_timeout` (~5s here) — a backend that exceeds the timeout is dropped and the gateway degrades gracefully (returns 200 without that backend's tools). A **dead** backend (connection refused) does not block; only a **slow/hung** one does.

**V4 — native hot path is fast.** In-process routing with no gRPC hop delivers p50 ~1.3ms,
p95 ~2.9ms at ~5,700 rps under 10 VUs. This is the latency saving that motivates the hybrid
architecture: native `mcp_router` handles `tools/call` routing; the broker retains caching,
lazy init, and session management.

## Architecture

```
run-v-tests.sh (curl + k6)
    -> Envoy :10000
        mcp_filter    (parse JSON-RPC -> dynamic metadata)
        mcp_router    (fan-out, prefix-merge, terminal)
            -> backend-a (server1) :9001  — 3 tools, controllable init delay
            -> backend-b (server2) :9002  — 2 tools, controllable init delay
Envoy admin :9901
backend-a   :9001  (also reachable from host for /__stats, /__reset)
backend-b   :9002  (also reachable from host for /__stats, /__reset)
```

The `MCP_INIT_DELAY` for each backend is controlled via the `BACKEND_A_INIT_DELAY` and
`BACKEND_B_INIT_DELAY` environment variables in `docker-compose.yml`. `run-v-tests.sh`
restarts `backend-b` with a 3s delay for V3, then restores it.
