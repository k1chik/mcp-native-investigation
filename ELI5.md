# ELI5: plain-language overview

---

## 1. The business problem

Imagine a mid-sized company. Engineers use AI agents (Claude, GPT, internal copilots) to do real work. Each agent can call **tools**: query the warehouse, post to Slack, file a ticket, look up a customer.

Those tools are exposed through **MCP servers** (Model Context Protocol, the standard for "tools an AI agent can call"). One server wraps a handful of tools, and a company quickly runs several. Four problems show up fast:

1. **Sprawl.** Every agent has to know about every server. Add a server, reconfigure every agent.
2. **Dangerous tools.** "Delete production database" shouldn't be callable by a junior's agent. How does the server know who's asking?
3. **Compliance.** "Who called what tool, when, on whose behalf?" Audit needs an answer.
4. **Cost.** Finance wants per-team, per-tool spend.

This is exactly what an **API gateway** does for HTTP. Put one box in front of everything: one front door, one place for identity, policy, and logging. That box, for MCP, is an **MCP gateway**. Kuadrant builds an open-source one, [`Kuadrant/mcp-gateway`](https://github.com/Kuadrant/mcp-gateway), on top of [**Envoy**](https://github.com/envoyproxy/envoy), the proxy used inside service meshes like Istio.

---

## 2. The picture

```
                      ┌─────────────────────────────────┐
[AI agent] ─────────▶ │             Envoy               │
                      │  (the gateway, runs the rules)  │
                      └────────────────┬────────────────┘
                          │                          │
                          ▼                          ▼
              ┌──────────────────────┐   ┌──────────────────────┐
              │  Local MCP server    │   │  Remote MCP server    │
              │  (in-cluster)        │   │  (public)             │
              └──────────────────────┘   └──────────────────────┘
```

The agent never sees the individual servers. It talks to the gateway; the gateway picks the backend, checks who's asking, decides if they're allowed, logs everything. Rules look like: *anyone* can discover tools; *admins* can call any tool; *regular users* can only call `get_weather`.

---

## The call flows, method by method

The single most useful mental model: **the gateway is a server to the agent *and* a client to the backends.** Most methods happen at two hops. Here is each one, showing where **native** (built-in Envoy) and the **broker** (`Kuadrant/mcp-gateway`) behave differently.

**`initialize`**: the handshake. Happens twice (agent to gateway, gateway to backend). The difference is timing:

```
NATIVE (eager):                                  BROKER (lazy):
  agent ──initialize──▶ gateway                    (at startup) broker ──initialize──▶ backends
            ├─▶ backend1                            agent ──initialize──▶ gateway
            └─▶ backend2   (waits for ALL)          agent ◀── answered immediately ──┘
  agent ◀── only after all reply ──┘                (backends were set up in the background)
  → a slow backend blocks the agent (5.3s)           → agent's initialize stays fast (238ms)
```

**`tools/list`**: "what tools exist?" Gateway asks backends, merges, and adds a per-server prefix:

```
  agent ──tools/list──▶ gateway
     native:  ──▶ backend1 + backend2   EVERY time (no cache)        → 10 lists = 10 hits per backend
     broker:  served from the broker's CACHE                          → 10 lists = 0 hits to backends
  agent ◀── merged + prefixed list ──┘   (server1__time, server2__time)
```

**`tools/call`**: "run this tool." Gateway routes to the one backend that owns it and strips the prefix back off:

```
  agent ──tools/call "server1__time"──▶ gateway
     gateway: read "server1" → backend1;  strip prefix → "time"       (rewrites the body)
     native:  in-process route to backend1                            → fast: p50 0.23ms
     broker:  the ext-proc ROUTER forwards it (the broker's /mcp does NOT forward calls)
  backend1 runs "time" → result ──▶ gateway ──▶ agent
```

**`ping`**: a health-check the **broker** sends to backends (drops a backend's tools if it stops answering). Native does not do this.

```
  broker ──ping──▶ backend   →   backend ◀── {} ──   (alive)
```

**`tools/list_changed`**: a notification that flows the other way (backend up to the agent): "my tools changed."

```
  backend ──list_changed──▶ gateway
     broker:  relays it to the agent over SSE + re-fetches just that backend
     native:  does NOT relay it (the agent's SSE channel returns 405)
```

**The pattern:** the backend owns the tools and answers about itself; the gateway owns aggregation, routing, sessions, and notifications. Native covers the per-request mechanics (parse, route, prefix, rewrite); the broker keeps the stateful and cross-cutting parts (cache, sessions, lazy init, relaying notifications). That is the residual.

---

## 3. Where the technical question hides

Inside Envoy, a request runs through a **filter chain**, small steps that each inspect it:

```
request → JWT check → ??? → RBAC check → routing → upstream MCP
            (identity)  (parse MCP)  (allow/deny)  (pick backend)
```

The "???" (*parse the MCP request and tell the rest of Envoy what's in it*) is the interesting step. Today `Kuadrant/mcp-gateway` does it by calling out to a separate program (`ext-proc`) over gRPC. That program parses the JSON-RPC body, finds the MCP method and tool name, sets headers so Envoy can route, manages sessions, connects to backends, strips a tool-name prefix, and handles tricky stateful flows. That is [`internal/mcp-router/`](https://github.com/Kuadrant/mcp-gateway/tree/main/internal/mcp-router) .

It works, but it is a tax: an extra ~5 ms gRPC hop on every request, a second service to deploy and monitor, and custom code that must track every MCP spec change.

---

## 4. What changed and why investigate now

In **April 2026**, Envoy 1.38 shipped a [**native MCP filter chain**](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/mcp_filter) built into Envoy itself. It can parse JSON-RPC bodies, expose method/tool/params to other filters, validate the spec, **rewrite the body** to strip prefixes, **aggregate** multiple backends behind one endpoint, and carry tracing.

If Envoy does natively what `ext-proc` does in custom code, **maybe we don't need ext-proc, or need a much smaller version.** That is the investigation, in five words: **how much of ext-proc disappears?**

---

## 5. The catch: it is not "delete everything"

The native filter handles the **mechanical** jobs well (parse, route, strip prefix, merge tool lists, carry a session ID). But it quietly skips a whole layer of operational behaviour that the broker does today. The honest way to see this is one piece at a time, using a simple analogy.

> A building has one **front-desk receptionist** in front of many specialist offices. Each office is a backend MCP server. The visitor is the AI agent.
> - **`ext-proc` today** = a *smart human receptionist with a notepad.*
> - **native Envoy** = a *very fast receptionist with no notepad and no discretion.*

### Piece 1: Remembering what the offices offer (the cache)
- **Old (broker):** keeps a list; answers "what can everyone do?" from memory.
- **New (native):** no memory. Every time anyone asks, it runs to **every** office and asks again.

### Piece 2: Re-checking only what changed
- **Old:** when one office says "my list changed," it re-checks **that one**.
- **New:** no memory, so it ends up re-asking **everyone**. If one office keeps shouting "changed!", the new receptionist runs to **all** offices each time.

### Piece 3: Saying hello without waiting for everyone (startup)
- **Old:** greets the visitor right away; contacts an office only when the visitor needs it.
- **New:** phones **every** office first and won't greet the visitor until **all** answer. One slow office makes **every** visitor wait.

### Piece 4: Different menus for different people (virtual servers)
- **Old:** can show each group its own allowed list of tools.
- **New:** everyone sees the full list. No filtering.

### Piece 5: A different key per office (per-backend auth)
- **Old:** uses the right key for each office.
- **New:** hands the **same** identity to every office.

### Piece 6: The one thing the new receptionist does better (the hot path)
- **Old:** a little slower. It is a separate program, so work is handed over and back (the gRPC hop).
- **New:** faster, because it is *inside* the building. For the most common errand, taking one request to one office (`tools/call`), this is a real win.

