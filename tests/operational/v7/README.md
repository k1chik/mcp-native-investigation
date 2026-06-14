# V7 — Prefix delimiter migration

**Type: documented analysis — no runtime test**

The tool name prefix delimiter differs between native `mcp_router` (`server1__tool`) and
the broker (`server1_tool`). This is a hard breaking change for existing deployments.

See [`v7-prefix-migration.md`](v7-prefix-migration.md) for the full analysis.
