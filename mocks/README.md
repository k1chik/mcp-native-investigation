# Mock MCP backends

Two small, controllable MCP servers that sit behind the gateway in the side-by-side test setup.

## Why custom mocks

The tests need to *control* the backend — inject delays, fire notifications, set tool counts — and measure behaviour on a quiet, deterministic target. A real or public MCP server cannot do that reliably.

## What they simulate

- **Two independent backends** (server1 on port 9001, server2 on port 9002) each advertising their own set of tools
- **Overlapping tool names** across both backends, so prefix-merge and collision handling are exercised
- **Configurable startup delay** to test what happens when one backend is slow to initialize
- **Configurable notification rate** to test how the gateway handles a backend that keeps signalling tool-list changes

## Transport

The gateway proxies HTTP, so these backends speak MCP over HTTP (POST JSON-RPC + an SSE stream for notifications), not stdio.

---

Code and configuration will be added here.
