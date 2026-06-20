# C5 — Single-server MCP gateway (no mcp-gateway)

**Status: PASS**

## What it proves

| ID | Claim |
|----|-------|
| C5 | `mcp_filter → ext_authz → router` is a complete MCP gateway for a single backend — no mcp-gateway or mcp_router needed. An external authorizer reads `envoy.filters.http.mcp` dynamic metadata and enforces tool-level policy using only native Envoy signals. |

For a single backend there is no need for tool-name prefixing or fan-out aggregation, so `mcp_router` and mcp-gateway add zero value. The minimal filter chain is:

```
mcp_filter  →  ext_authz  →  router
```

## Filter chain comparison

| Lane | Chain | Tool names |
|------|-------|-----------|
| C2 (multi-backend) | `mcp_filter → ext_authz → mcp_router` | `server1__tool1` (prefix added by `mcp_router`) |
| C5 (single-backend) | `mcp_filter → ext_authz → router` | `tool1` (plain — no prefix) |

The smoke test asserts the absence of the `server1__` prefix to confirm `mcp_router` is not in the chain.

## Environments

### Docker Compose (OPA) — local

Uses OPA as the `ext_authz` peer. No cluster needed.

```bash
docker compose up -d
./smoke.sh
docker compose down
```

Or via the top-level runner:

```bash
./run-tests.sh c5
```

### Kuadrant / kind (Authorino) — `kuadrant/`

Uses Authorino as the `ext_authz` peer on a real kind cluster with Kuadrant. Proves the same filter chain works with Kuadrant's auth stack and no mcp-gateway. See [`REPORT.md`](REPORT.md) for full findings and analysis.

```bash
cd kuadrant
./create-env.sh
kubectl -n mcp-demo port-forward svc/envoy138 10000:10000 9901:9901
./smoke.sh
```

## OPA policy (`authz/policy.rego`)

- Allows all non-tool-call requests (no `params.name` in metadata).
- Allows any `tools/call` except `tool2`.
- Denies `tool2` → 403.

C5 blocks `"tool2"` (plain name). C2 blocks `"server1__tool2"` (prefixed). The metadata path and `ext_authz` filter config are identical in both lanes — the only difference is tool-name format.

## Troubleshooting

**Deny test returns 200 instead of 403**
Check what OPA received:
```bash
docker compose logs authz | grep -A20 filter_metadata
```
Find the actual key in `envoy.filters.http.mcp` and update `authz/policy.rego` accordingly.

**403 on tools/list or initialize**
The `is_tools_call` check is not working — OPA is treating a missing key as truthy. Check OPA decision logs for the full input shape.

**ext_authz connection refused**
OPA gRPC starts on `:9191`. Check `docker compose logs authz` for startup errors.
The `authz` cluster in `envoy.yaml` must use `http2_protocol_options`.

**OPA amd64/arm64 mismatch**
The OPA Envoy image is amd64-only. Docker Desktop handles emulation on Apple Silicon via `platform: linux/amd64` in `docker-compose.yml`.
