# Primer: the moving parts, in plain terms

> Read this first if Envoy, MCP, or `Kuadrant/mcp-gateway` are new to you. It explains every piece the investigation touches, with small examples. No prior background needed.

---

## The problem this solves

Imagine a mid-sized company. Engineers use AI agents (Claude, GPT, internal copilots) to do real work. Each agent can call **tools**: query the warehouse, post to Slack, file a ticket, look up a customer.

Those tools are exposed through **MCP servers**. One server wraps a handful of tools, and a company quickly runs several. Four problems show up fast:

1. **Sprawl.** Every agent has to know about every server. Add a server, reconfigure every agent.
2. **Dangerous tools.** "Delete production database" shouldn't be callable by a junior's agent. How does the server know who's asking?
3. **Compliance.** "Who called what tool, when, on whose behalf?" Audit needs an answer.
4. **Cost.** Finance wants per-team, per-tool spend.

This is exactly what an **API gateway** does for HTTP. Put one box in front of everything: one front door, one place for identity, policy, and logging. That box, for MCP, is `Kuadrant/mcp-gateway`.

---

## Key components

**MCP server.** A program that offers a set of *tools* an AI agent can use: "look up the weather," "file a ticket," "run a query." **MCP** (Model Context Protocol) is the agreed way for an agent to talk to those tools.

**Tool.** One action a server offers, with a name like `get_weather`.

**JSON-RPC.** The format MCP messages are written in: a small piece of JSON that says "call this method with these arguments." A tool call looks roughly like this:

```
{ "method": "tools/call", "params": { "name": "get_weather", "arguments": { ... } } }
```

The part to remember: **the tool name sits inside the message body** (`params.name`), not in a separate label on the outside.

**The gateway.** One front door in front of many MCP servers. The agent only ever talks to [`Kuadrant/mcp-gateway`](https://github.com/Kuadrant/mcp-gateway); the gateway works out which server to use, checks permissions, and keeps the logs.

**Envoy.** A fast, widely-used proxy. The gateway is built on top of [Envoy](https://github.com/envoyproxy/envoy). A request passing through Envoy goes through a **filter chain**: a line of small steps, each one looking at the request and doing a single job (check identity, read the message, route it).

**ext-proc.** Today, one of those steps hands the MCP-specific work to a [*separate program*](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_proc_filter): read the message, find the tool, rewrite it, route it. "ext-proc" is short for *external processor*. It works fine, but handing work to a separate program and getting it back adds a small delay to every request.

**The native MCP filters (new in Envoy 1.38).** Newer Envoy has two built-in steps that do much of that same work *inside* Envoy, with no separate program:
- `mcp_filter`: the **reader** - parses the message and makes its details available to the steps that follow.
- `mcp_router`: the **router** - rewrites the message and sends it to the right server.

**ext_authz.** An Envoy filter that asks an outside service "should I allow this?" It sends the request details — including whatever `mcp_filter` left in the metadata — to that service over gRPC, then waits for a yes or no. It is the link between Envoy and the policy layer.

**Authorino.** The piece that answers "is this caller allowed to do this?" It receives the request from `ext_authz`, reads the tool name out of the metadata, and says allow or deny. In this investigation we use **OPA (Open Policy Agent)** in its place — OPA is a CNCF open-source policy engine where rules are written in a language called Rego. Authorino and OPA both speak the same gRPC protocol `ext_authz` expects, so swapping one for the other is a config change, not a structural one.

**`router` vs `mcp_router` — two separate things.** Every Envoy filter chain needs a terminal filter that actually sends the request somewhere. The standard one is `envoy.filters.http.router` — it has been in Envoy forever and just forwards the request to a cluster based on the route config. `envoy.filters.http.mcp_router` (new in Envoy 1.37+) is a drop-in replacement for it that adds MCP awareness: fan-out across multiple backends, tool-list merging, prefix-add on `tools/list`, prefix-strip on `tools/call`. If you only have one backend, `mcp_router` adds nothing — you use the plain `router`. That is exactly what C5 does.

**Istio.** In production, Envoy doesn't run on its own - it runs inside Istio (a service mesh that manages proxies across a cluster). Istio ships with a specific Envoy version baked in, which is why "what Istio version are we on?" decides whether the new native filters are even available yet.

---

## Required reading

| Resource | Why |
|---|---|
| [MCP specification](https://modelcontextprotocol.io/specification) | the wire protocol the whole investigation is about |
| [Envoy native MCP filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/mcp_filter) | the filter being evaluated |
| [ext_proc filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_proc_filter) | what it replaces |
| [Kuadrant/mcp-gateway#809](https://github.com/Kuadrant/mcp-gateway/issues/809) | the original issue defining the investigation scope |
| [CONNLINK-1026](https://redhat.atlassian.net/browse/CONNLINK-1026) | the operational evaluation adding the caching and latency layer |
| [Prior Wasm investigation](https://github.com/maleck13/mcp-gateway/tree/mcp-wasm) | the earlier proposal to replace ext-proc with a Wasm filter, before the native filter existed |
| [Envoy AI Gateway - MCP](https://aigateway.envoyproxy.io/docs/0.5/capabilities/mcp/) | reference implementation showing how another project approached native MCP support |
| [`initializeMCPSeverSession` - `request_handlers.go:665`](https://github.com/Kuadrant/mcp-gateway/blob/v0.7.0/internal/mcp-router/request_handlers.go#L665) | why `mcp-gateway` chose lazy backend session init - understanding this is required before evaluating what native's eager behavior costs |

---

## The life of a request

Three requests drive the investigation. Each one exposes a different difference between the native path and the broker.

---

### tools/call - the hot path

The agent runs a tool. This is the frequent, latency-sensitive path and the primary target of the investigation.

**Native (in-process, no gRPC hop):**

```
agent
  |  tools/call { "name": "serverA__get_weather" }
  v
mcp_filter    -- parses body, writes tool name + method to dynamic metadata
  |
mcp_router    -- reads "serverA" from the prefix, strips it,
  |              rewrites body to { "name": "get_weather" }, routes to backend A
  v
backend A     -- receives { "name": "get_weather" }, runs the tool
  |
  v
agent         -- result
```

**Broker (ext-proc, gRPC hop on every request):**

```
agent
  |  tools/call { "name": "serverA_get_weather" }   ← single underscore (broker convention)
  v
Envoy         -- receives request, hands off to ext-proc over gRPC
  |
ext-proc      -- parses body, adds routing headers, decides backend
  |
Envoy         -- receives modified request back from ext-proc, routes
  |
  v
backend A     -- receives { "name": "get_weather" }, runs the tool
  |
  v
agent         -- result
```

The native path is all in-process. The broker adds a gRPC round-trip to ext-proc on every single request - that is the latency tax the investigation is measuring.

---

### tools/list - discovery (fan-out)

The agent asks what tools are available. This happens less often but drives two key differences.

```
                             tools/list
                                  |
agent --> gateway -+-> backend A --> [a1, a2] --+
                   |                             |
                   +-> backend B --> [b1, b2] --+--> prefix + merge --> agent
                   |                             |
                   +-> backend C --> [c1, c2] --+

                   result: [serverA__a1, serverA__a2,
                             serverB__b1, serverB__b2,
                             serverC__c1, serverC__c2]
```

**Native:** hits all backends on every discovery call - no cache. Ten backends means ten upstream requests every time an agent asks what it can do.

**Broker:** returns a cached list. Only re-fetches when a backend fires a `tools/list_changed` notification. One discovery call = zero upstream hits until something changes.

---

### initialize - startup (eager vs lazy)

Before any calls can happen, the gateway and each backend exchange an `initialize` handshake. How the gateway handles a slow backend here is one of the sharpest differences.

**Native - eager (blocks until all backends respond):**

```
client
  |  initialize
  v
gateway -+-> backend A ......... ok   (12 ms)
         |
         +-> backend B ......... ok   (15 ms)
         |
         +-> backend C ......... ok   (5000 ms, slow)
         |
         | (waits for all three before responding)
         v
    respond to client          (~5027 ms total)
```

**Broker - lazy (responds immediately, connects backends in the background):**

```
client
  |  initialize
  v
gateway --> respond to client immediately
  |
  +--> backend A  (connecting in background)
  +--> backend B  (connecting in background)
  +--> backend C  (slow - still connecting in background, client unaffected)
```

One slow backend delays every connecting client in the native path. The broker shifts that cost to the background - the client connects instantly and tools become available as backends come up.

---

## Who answers what: the two layers

The thing that trips everyone up: **the gateway is both a server *and* a client.** It is an MCP **server** to the agent, and an MCP **client** to each backend. So a method like `initialize` happens **twice**: once agent to gateway, once gateway to backend.

Three roles:

| Role        | Who                                    | Acts as                                        |
| ----------- | -------------------------------------- | ---------------------------------------------- |
| **Client**  | the AI agent                           | sends requests                                 |
| **Gateway** | native Envoy or `Kuadrant/mcp-gateway` | server to the agent and client to the backends |
| **Backend** | the actual MCP servers                 | own the real tools                             |

One naming point: **"the broker" is a component of `Kuadrant/mcp-gateway`**, not a separate thing. `Kuadrant/mcp-gateway` has three parts: the **router** (parses and rewrites on the data path), the **broker** (aggregates, caches, holds sessions), and the **controller** (Kubernetes config). The core question the investigation explores, drawn from [issue #809](https://github.com/Kuadrant/mcp-gateway/issues/809), is narrow: **can native Envoy replace the router?** The broker and controller stay either way.

Who answers each method, and where native and broker differ:

| Method | Who answers | native vs broker |
|---|---|---|
| `initialize` | both layers (gateway and each backend) | native **eager** (blocks on slowest backend); broker **lazy** (backends in the background) |
| `tools/list` | backend lists; gateway merges and prefixes | native **no cache** (asks every backend every time); broker **caches** |
| `tools/call` | backend runs it; gateway routes and strips prefix | both route to one backend; broker's call goes via the ext-proc router, not its `/mcp` |
| `ping` | backend answers; the **broker** sends it | only the broker health-checks backends; native doesn't |
| `tools/list_changed` (a notification, flows up) | backend emits, gateway relays to client | broker **relays** (over SSE); native **doesn't** |

---

## A mental model: native vs broker

> A building has one **front-desk receptionist** in front of many specialist offices. Each office is a backend MCP server. The visitor is the AI agent.
> - **`ext-proc` today** = a *smart human receptionist with a notepad.*
> - **native Envoy** = a *very fast receptionist with no notepad and no discretion.*

The native receptionist is faster for the most common errand (taking one request to one office). But it has no memory of what each office offers, cannot show different visitors different menus, and contacts every office before greeting anyone. The sections below unpack each of those differences.

---

## The bits that trip people up

### 1. Why tool names get a prefix, and why it is then removed

When the gateway combines tools from several backends into one list, it adds a per-backend tag to each name. So Backend A's `get_weather` becomes `serverA__get_weather` (with a double underscore), and Backend B's becomes `serverB__get_weather`. Two reasons:

- **Names can collide.** Two backends can both offer a tool called `get_weather`. Without a tag, the agent couldn't tell them apart.
- **The tag also says where to route.** When the agent later calls `serverA__get_weather`, the gateway reads `serverA` and knows which backend to send it to.

But here is the catch: **Backend A only ever knew its tool as `get_weather`.** It has no idea the gateway is presenting it as `serverA__get_weather`. So before forwarding the call, the gateway removes the tag:

```
agent calls:   serverA__get_weather
gateway:       reads "serverA" → choose Backend A
               removes the tag → "get_weather"
forwards:      get_weather        ← the name Backend A actually recognizes
```

If the gateway didn't remove it, Backend A would receive `serverA__get_weather`, find no tool by that name, and return an error. Removing the tag is what makes the routed call work.

**One gotcha: the delimiter changed.** The old broker used a single underscore (`serverA_get_weather`). The native filter uses a double underscore (`serverA__get_weather`). Any client that learned tool names from the broker and hardcoded them will break when switching to the native filter — it is not a config flag, it is a rename.

### 2. Why "rewrite the body" is a big deal

The tool name lives *inside* the JSON body, not in an outside label. So removing the tag means editing the message body as it flows through, which is harder than just setting a label. It is exactly why an [earlier review](https://github.com/maleck13/mcp-gateway/tree/mcp-wasm) ruled out the native filter (it could read the body but not change it). It can change it now.

### 3. Discovery vs. doing

`tools/list` (what's available) happens occasionally. `tools/call` (do the thing) is the frequent, time-sensitive path. The investigation cares about two things: not slowing down the common call, and not making discovery expensive.

### 4. Sessions

A conversation with a backend often spans several requests. The gateway keeps a *session*: a thread that ties those requests together, and links the agent's session to each backend's session. Who keeps that thread, and how, is one of the open questions.

### 5. What the policy layer can and cannot see

`mcp_filter` reads the request body and makes these fields available to the next step (`ext_authz`):

- `method` — e.g. `tools/call`
- `params.name` — the tool name
- `id`, `jsonrpc`, `is_mcp_request`

It does **not** expose `params.arguments` — the actual inputs the agent sent to the tool. So a policy that needs to say "block any call to `run_query` where the argument `table` is `users`" cannot do that with the metadata alone. It would need a separate ext-proc step to inspect the body. For most real-world policies (allow/deny by tool name, by caller identity, by time of day) the available fields are enough.

### 6. Elicitation

Sometimes a tool needs to ask the user a follow-up in the middle of a call: "which account did you mean?" Getting that follow-up back to the right backend is fiddly and stateful, and it is one of the jobs that stays custom.

### 7. "Native vs. broker": what is being compared

"Native" means the built-in Envoy filters. "Broker" (or "ext-proc") means the current custom gateway code. The whole investigation is one question: **how much can move from the custom code to the built-in filters, and what has to stay?**

---

## Two ways to deploy

The investigation uncovered two distinct deployment shapes. They are not the same problem.

**Single backend — no broker needed.**
One MCP server behind Envoy. No name collisions, no fan-out, no prefixing. The full filter chain is just:

```
mcp_filter  →  ext_authz  →  router
```

`mcp_filter` reads the body and writes the tool name to metadata. `ext_authz` asks OPA or Authorino "allow this tool call?" The standard Envoy `router` forwards to the one backend. No `mcp_router`, no `mcp-gateway`, no broker. Tool names stay plain (`get_weather`, not `serverA__get_weather`).

This is the right shape for a team that has one MCP server and wants policy enforcement on it. No extra infrastructure.

**Multiple backends — broker stays for some jobs.**
Several MCP servers behind one gateway. The native filter handles the hot path well (`tools/call` routing, prefix strip, fan-out). But some jobs remain broker-side: caching the tool list, relaying `list_changed` notifications, connecting to backends lazily, per-backend credentials, and per-tenant tool subsets. The expected shape is a hybrid — native handles the frequent calls, broker keeps the stateful pieces.

---

## Mini-glossary

| Term | In plain words |
|---|---|
| **ext-proc** | The separate helper program Envoy hands MCP work to today |
| **filter chain** | The line of small steps a request passes through inside Envoy |
| **mcp_filter / mcp_router** | The new built-in steps: the reader and the router |
| **prefix / delimiter** | The `serverA__` tag added to tool names so the gateway knows where to route a call. The `__` is the delimiter. Native Envoy uses double underscore; the old broker used single — that difference is a breaking rename when switching. |
| **fan-out / aggregate** | Asking all backends and combining their answers into one |
| **dynamic metadata** | The details the reader leaves for later steps to use (instead of outside labels or headers) |
| **session** | The thread that ties a multi-message conversation together |
| **elicitation** | A backend asking the user a follow-up mid-call |
| **ext_authz** | The Envoy filter that calls an outside policy service (OPA or Authorino) and gets back allow or deny |
| **OPA (Open Policy Agent)** | A CNCF open-source policy engine; rules are written in Rego. Used in this investigation as the ext_authz peer. |
| **Authorino** | Kuadrant's allow/deny permission checker; the ext_authz peer used in production Kuadrant deployments |
| **Istio** | The production system that runs Envoy across a cluster; it ships a fixed Envoy version |
| **Gateway API / HTTPRoute / AuthPolicy** | Config pieces that attach routing and permission rules to backends |
| **MCPVirtualServer** | The gateway feature that shows different users a different subset of tools |
| **SSE (server-sent events)** | A way to stream a response back piece by piece instead of all at once |
