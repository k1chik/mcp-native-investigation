# V7 — Prefix delimiter migration

**Type: documented analysis — no runtime test needed**

## What this covers

| ID | What it measures | CONNLINK-1026 |
|----|-----------------|---------------|
| V7 | **Breaking prefix rename**: `mcp_router` hard-codes the `__` delimiter; the broker uses a configurable single-underscore convention (`server1_tool`) — migrating requires renaming every advertised tool | Discovered in investigation, referenced in CONNLINK-1026 |

## The finding

The tool name delimiter used by `mcp_router` and the broker are **different and incompatible**:

| Side | Example tool name | Delimiter | Configurable? |
|------|-------------------|-----------|---------------|
| Native `mcp_router` | `server1__tool1` | `__` (double underscore) | No — hard-coded in `mcp_router.cc` |
| Broker | `server1_tool1` | `_` (single underscore) | Yes — `ToolPrefix` field per server |

This is a **breaking change** for any existing deployment migrating from the broker to
native `mcp_router`. Every tool name that clients have already discovered changes:

```
broker advertises:    server1_get_weather
native advertises:    server1__get_weather
```

An agent that stored or hard-coded `server1_get_weather` will get a "tool not found" error
after migration. This is not a config flag — it requires clients to re-discover tools.

## Implications for migration

1. **Not a zero-downtime rename.** Clients must re-run `tools/list` to get the new names.
2. **Cannot run broker and native in parallel** on the same tool namespace without name collisions.
3. **The double-underscore is not configurable** in Envoy `v1.38.0`. A configurable delimiter
   would be a candidate upstream contribution (small, self-contained, justifiable by a real
   consumer need).

## No runtime test

The delimiter difference is directly observable from:
- A `tools/list` response via native (returns `server1__tool1`)
- A `tools/list` response via the broker (returns `server1_tool1` with default config)

This is verified empirically in C3 (native) and is a code-level fact for the broker.
No additional runtime test adds information.
