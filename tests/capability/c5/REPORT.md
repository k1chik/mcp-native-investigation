# C5: Per-Tool Access Control Without mcp-gateway

LFX Mentorship 2026 (Jun–Aug), Kuadrant Agentic Gateway

---

## Context

**Single-server deployment** means one AI tool server (e.g. a service that exposes tools like `search`, `summarize`, `query-db`) sits behind Envoy, and all AI client traffic goes through Envoy first.

Today, Kuadrant's `mcp-gateway` uses a custom Go component called **ext-proc** to handle access control. It is an external process that Envoy calls for every incoming request. ext-proc reads the request, pulls out the tool name, and hands it to **Authorino** — Kuadrant's policy engine — which says allow or deny.

Envoy 1.38 added a **native MCP filter** (`mcp_filter`) that does what ext-proc does — parse AI tool requests and extract the tool name — without any custom code. The question is whether we can wire that directly to Authorino and skip mcp-gateway entirely.

```
Before (mcp-gateway)                 After (native filter chain)

 AI Client                            AI Client
     │                                    │
     ▼                                    ▼
   Envoy                                Envoy
     │                             ┌─────────────┐
     ▼                             │  mcp_filter │ ← reads tool name
  ext-proc ──► Authorino           │  ext_authz  │──► Authorino
 (custom Go)   (policy)            │  router     │    (policy)
     │                             └──────┬──────┘
     ▼                                    │
  MCP Server                          MCP Server
```

---

## Answer

**Yes — it works.** Envoy's native filter reads the tool name from each request and passes it to Authorino. Authorino enforces the policy correctly. No custom code or mcp-gateway is needed.

There is one version-gap to be aware of before putting this in production — covered in the [Deployment Notes](#deployment-notes) section at the end.

---

## What We Tested

We used a mock MCP server (`server1`) with 3 tools: `tool1`, `tool2`, and `tool3`. The policy was simple: allow everything except `tool2`.

We wanted to confirm two things:
1. Does Envoy's native filter correctly read the tool name out of real MCP requests?
2. Does Authorino receive that name and make the right allow/deny call?

We also ran a set of edge cases — malformed requests, missing fields, wrong HTTP verb — to make sure the system fails safely when it gets unexpected input.

**Setup:**

- Local Kubernetes cluster (kind)
- Kuadrant installed via Helm
- Istio 1.27
- Envoy v1.38.0 (standalone deployment, not bundled with Istio)
- Authorino (Kuadrant's policy engine)
- Mock MCP server — `server1`, 3 tools

```
┌──────────────────────────────────────────────┐
│  Kind Cluster                                │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │  Envoy v1.38.0                         │  │
│  │                                        │  │
│  │  mcp_filter ──► ext_authz ──► router   │  │
│  │                    │                   │  │
│  └────────────────────┼───────────────────┘  │
│                       │                      │
│                  Authorino                   │
│                  (allow/deny by tool name)   │
│                                              │
│  server1 — tool1, tool2, tool3               │
└──────────────────────────────────────────────┘
```

**Filter chain — confirmed via live config dump at runtime:**

```
mcp_filter          ext_authz           router
    │                   │
 reads tool         calls Authorino
 name from          with tool name
 request
```

---

## Test Results

Policy: allow all tools except `tool2`. 13 tests run via `kuadrant/smoke.sh`.

| # | What we sent | What Envoy extracted | Decision | Result | Evidence |
|---|---|---|---|---|---|
| 1 | `initialize` | `method=initialize` | Allow | ✅ 200 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |
| 2 | `tools/list` | `method=tools/list` | Allow | ✅ 200 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |
| 3 | `tools/call tool1` | `method=tools/call, name=tool1` | Allow | ✅ 200 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |
| 4 | `tools/call tool2` | `method=tools/call, name=tool2` | **Deny** | ✅ 403 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |
| 5 | `tools/call tool3` | `method=tools/call, name=tool3` | Allow | ✅ 200 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |
| 6 | `tools/call tool99` (unknown tool) | `method=tools/call, name=tool99` | Allow | ✅ 200 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |
| 7 | `tools/call` with no tool name | `method=tools/call` (no name field) | Deny | ✅ 403 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |
| 8 | `tools/call` with empty name `""` | `method=tools/call, name=` | Allow | ✅ 200 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |
| 9 | `tools/call tool2` + extra fields | `method=tools/call, name=tool2` | **Deny** | ✅ 403 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |
| 10 | Request with no `method` field | nothing extracted | Deny | ✅ 403 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |
| 11 | Empty request body | nothing extracted | Deny | ✅ 403 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |
| 12 | Non-JSON body | could not parse | — | ✅ 400 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |
| 13 | GET request (wrong verb) | nothing extracted | Deny | ✅ 403 | [c5.txt](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt) |

---

## Evidence

Envoy's access log was configured to print exactly what the native filter extracted from each request. This makes the evidence direct — you can see what Authorino actually received, not just what status code the client got back.

| Request | What the filter extracted | Status |
|---|---|---|
| `tools/call tool1` | `{"method":"tools/call","params":{"name":"tool1"}}` | 200 |
| `tools/call tool2` | `{"method":"tools/call","params":{"name":"tool2"}}` | 403 |
| `tools/call` (no name) | `{"method":"tools/call"}` | 403 |
| empty body | `null` | 403 |
| GET request | `null` | 403 |

**Fail-closed:** if Authorino is unreachable, requests are denied — nothing slips through. During testing, 3 Authorino-unreachable events were introduced deliberately. Envoy stats confirmed `failure_mode_allowed: 0`: none got through. [Evidence](https://github.com/k1chik/mcp-native-investigation/blob/master/results/c5.txt)

---

## Two Things to Know Before Deploying

**1. Metadata forwarding must be turned on explicitly.**
Envoy does not forward what the filter extracts to Authorino by default. `metadata_context_namespaces` must be set in the `ext_authz` filter config. Without it, Authorino receives nothing and cannot make a decision.

**2. OPA policy syntax must be kept simple.**
The version of OPA bundled with Kuadrant does not support newer Rego syntax (`if` keyword, `default allow`, named helper rules). Policies must use flat `allow { }` rules.

Both are documented with working examples in `kuadrant/manifests/authconfig.yaml`.

---

## Deployment Notes <a name="deployment-notes"></a>

This POC ran Envoy 1.38 as a **standalone deployment**, not through Istio. This is because the current Istio release (1.27) bundles Envoy 1.34 — the native MCP filter only exists in 1.38+. As a result, we also had to use `AuthConfig` (Authorino's lower-level API) directly instead of Kuadrant's `AuthPolicy`, which requires Istio in the request path.

These are both version-gap issues, not design problems. Once Istio ships with Envoy 1.38+ (estimated Istio 1.29–1.30), the steps to move to the full integrated setup are:

1. Replace the standalone Envoy deployment with an `EnvoyFilter` on the Istio Gateway
2. Replace `AuthConfig` with a Kuadrant `AuthPolicy` on the `HTTPRoute`
3. Remove mcp-gateway from the single-server path

Until then, the standalone Envoy 1.38 approach used in this POC is a working interim — it connects directly to Authorino and requires no changes to the Kuadrant operator or Istio installation.

Reproducible setup: `kuadrant/create-env.sh` · `kuadrant/smoke.sh` · `kuadrant/manifests/`

---

## Findings

The native filter chain works end-to-end for single-server deployments. All 13 tests passed, including edge cases. The fail-closed behavior held under simulated Authorino outages.

Whether and when to adopt this as the default single-server path is a call for the mentors. The data supports it — the open question is timing relative to Istio's Envoy 1.38 adoption.
