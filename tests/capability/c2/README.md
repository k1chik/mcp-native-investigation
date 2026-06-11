# C2: native-lane-authz

**What it proves:** An external authorizer can read `envoy.filters.http.mcp` dynamic metadata and allow/deny MCP tool calls by tool name — without any header injection from `ext-proc`.

This settles Q2 from issue #809: *"Can Authorino read native metadata directly - no header conversion?"*

---

## How it works

```
client
  | tools/call { "name": "server1__tool2" }
  v
mcp_filter    writes  ->  dynamic_metadata["envoy.filters.http.mcp"]["tool_name"] = "server1__tool2"
  |
ext_authz     reads   ->  CheckRequest.attributes.metadata_context.filter_metadata
  |                        ["envoy.filters.http.mcp"]["tool_name"]
  |           OPA evaluates data.authz.allow -> false (tool is blocked)
  v
  403 PERMISSION_DENIED   (mcp_router never runs)
```

For allowed tools (e.g. `server1__tool1`), `ext_authz` returns `OK` and `mcp_router` routes normally.

The key config line in `envoy.yaml`:
```yaml
metadata_context_namespaces:
  - envoy.filters.http.mcp
```
This tells Envoy to embed the MCP metadata in the `CheckRequest`. Without it, OPA would see an empty metadata context.

---

## OPA policy (`authz/policy.rego`)

- Allows all non-tool-call requests (no `tool_name` in metadata).
- Allows any `tools/call` except `server1__tool2`.
- Denies `server1__tool2` → returns 403 to the client.

The policy is deliberately minimal. In production, the same pattern covers arbitrary allow-lists, deny-lists, or JWT-claim-based rules.

---

## How to run

```bash
docker compose up -d
./smoke.sh
docker compose down
```

Expected output (abbreviated):
```
server1__tool1 -> ALLOWED (200) ✓
server1__tool2 -> DENIED (403) ✓  (OPA read tool_name from metadata)
server2__tool1 -> ALLOWED (200) ✓
OVERALL PASS
```

---

## Troubleshooting

**Deny test returns 200 instead of 403**
- `mcp_filter` may use a different field name than `tool_name`. Check:
  ```bash
  docker compose logs authz | grep -A20 filter_metadata
  ```
  Find the actual key in `envoy.filters.http.mcp` and update `authz/policy.rego`.

**403 on tools/list or initialize**
- The policy's `has_mcp_tool_name` check is not working — OPA is treating a missing
  key as truthy. Check OPA decision logs for the full input shape.

**ext_authz connection refused**
- OPA gRPC starts on port 9191. Check: `docker compose logs authz` for startup errors.
- The `authz` cluster in `envoy.yaml` must use HTTP/2 (`http2_protocol_options`).

**OPA amd64/arm64 mismatch**
- The OPA Envoy image is amd64-only. Docker Desktop handles emulation on Apple Silicon
  via `platform: linux/amd64` in `docker-compose.yml`. Performance is slightly lower
  but correctness is unaffected.
