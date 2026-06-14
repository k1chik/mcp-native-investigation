# V2 — SSE relay / notification fanout

Tests whether native Envoy's `mcp_router` relays `tools/list_changed` notifications
from backends to clients.

## What this lane checks

| ID | What it measures | CONNLINK-1026 |
|----|-----------------|---------------|
| V2 | **No SSE relay** — gateway returns 405 on client GET (no client-facing channel); `mcp_router` opens zero GET connections to backends (no backend subscription channel) | Craig Brookes concern #3 (fanout storm) |

## Prerequisites

- `docker`
- `python3`

## How to run

```bash
docker compose up -d
./run-v2.sh
docker compose down
```

## Expected output

```
########  V2 Part A — client-side SSE relay  ########
  GET http://localhost:10000 (Accept: text/event-stream) -> HTTP 405
  V2 Part A PASS — 405 Method Not Allowed: gateway has no client-facing SSE channel

########  V2 Part B — backend-side SSE connections  ########
  backend-a sse_get_connections_total = 0  (backend-a pushes list_changed every 2s)
  backend-b sse_get_connections_total = 0
  V2 Part B PASS — mcp_router opened ZERO GET SSE connections to either backend

V2 verdict: native mcp_router has NO SSE relay in either direction.
```

## Key finding

`mcp_router` is purely request-driven. It has no subscription channel to backends
and no push channel to clients:

- **Client GET → 405**: the gateway accepts only POST. Clients cannot receive
  server-initiated events.
- **Backend SSE connections = 0**: even after `initialize` and `tools/list`,
  `mcp_router` never opens a GET SSE connection to any backend. It cannot receive
  `tools/list_changed` or `sampling/createMessage` from backends.

The CONNLINK-1026 concern framed this as a "fanout storm" (misbehaving backend spamming
`list_changed` → re-fan-out to all backends). The actual native picture is different:
native cannot receive those notifications at all, so there is no notification-driven storm.
The real cost is V1 — every client `tools/list` is already a live fan-out regardless of
whether backends send notifications.

## Architecture

```
run-v2.sh (curl)
    -> Envoy :10000
        mcp_filter    (parse JSON-RPC -> dynamic metadata)
        mcp_router    (fan-out, terminal — no SSE subscribe)
            -> backend-a (server1) :9001  — pushes list_changed every 2s
            -> backend-b (server2) :9002  — silent
backend-a /__stats exposes sse_get_connections_total (how many GET SSE connections it received)
```
