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

## The cast of characters

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
- `mcp_filter`: the **reader** — parses the message and makes its details available to the steps that follow.
- `mcp_router`: the **router** — rewrites the message and sends it to the right server.

**Authorino.** The piece that answers "is this caller allowed to do this?" It reads what the reader produced and says allow or deny.

**Istio.** In production, Envoy doesn't run on its own — it runs inside Istio (a service mesh that manages proxies across a cluster). Istio ships with a specific Envoy version baked in, which is why "what Istio version are we on?" decides whether the new native filters are even available yet.

---

## How one request flows

Two kinds of request matter.

**1. "What can I do?" — `tools/list` (discovery)**

```
agent → gateway → ask each backend for its tools → combine into one list → send back to agent
```

**2. "Do this." — `tools/call` (the actual work)**

```
agent → gateway → pick the right backend → forward the call → send the result back
```

Most traffic is the second kind, which is why its speed matters most.

---

## Who answers what: the two layers

The thing that trips everyone up: **the gateway is both a server *and* a client.** It is an MCP **server** to the agent, and an MCP **client** to each backend. So a method like `initialize` happens **twice**: once agent to gateway, once gateway to backend.

Three roles:

| Role | Who | Acts as |
|---|---|---|
| **Client** | the AI agent | sends requests |
| **Gateway** | native Envoy or `Kuadrant/mcp-gateway` | server to the agent and client to the backends |
| **Backend** | the actual MCP servers | own the real tools |

One naming point: **"the broker" is a component of `Kuadrant/mcp-gateway`**, not a separate thing. `Kuadrant/mcp-gateway` has three parts: the **router** (parses and rewrites on the data path), the **broker** (aggregates, caches, holds sessions), and the **controller** (Kubernetes config). The core question the investigation explores, drawn from [issue #809](https://github.com/Kuadrant/mcp-gateway/issues/809), is narrow: **can native Envoy replace the router?** The broker and controller stay either way.

Who answers each method, and where native and broker differ:

| Method | Who answers | native vs broker |
|---|---|---|
| `initialize` | both layers (gateway and each backend) | native **eager** (blocks on slowest backend); broker **lazy** (backends in the background) |
| `tools/list` | backend lists; gateway merges and prefixes | native **no cache** (asks every backend every time); broker **caches** |
| `tools/call` | backend runs it; gateway routes and strips prefix | both route to one backend; broker's call goes via the ext-proc router, not its `/mcp` |
| `ping` | backend answers; the **broker** sends it | only the broker health-checks backends; native doesn't |
| `tools/list_changed` (a notification, flows up) | backend emits, gateway relays to client | broker **relays** (over SSE); native **doesn't** |

> Full call-flow diagrams for each method are in [`ELI5.md`](ELI5.md) ("The call flows, method by method").

---

## A mental model: native vs broker

> A building has one **front-desk receptionist** in front of many specialist offices. Each office is a backend MCP server. The visitor is the AI agent.
> - **`ext-proc` today** = a *smart human receptionist with a notepad.*
> - **native Envoy** = a *very fast receptionist with no notepad and no discretion.*

The native receptionist is faster for the most common errand (taking one request to one office). But it has no memory of what each office offers, cannot show different visitors different menus, and contacts every office before greeting anyone. The sections below unpack each of those differences.

---

## The bits that trip people up

### 1. Why tool names get a prefix, and why it is then removed

When the gateway combines tools from several backends into one list, it adds a per-backend tag to each name. So Backend A's `get_weather` becomes `serverA_get_weather`, and Backend B's becomes `serverB_get_weather`. Two reasons:

- **Names can collide.** Two backends can both offer a tool called `get_weather`. Without a tag, the agent couldn't tell them apart.
- **The tag also says where to route.** When the agent later calls `serverA_get_weather`, the gateway reads `serverA` and knows which backend to send it to.

But here is the catch: **Backend A only ever knew its tool as `get_weather`.** It has no idea the gateway is presenting it as `serverA_get_weather`. So before forwarding the call, the gateway removes the tag:

```
agent calls:   serverA_get_weather
gateway:       reads "serverA" → choose Backend A
               removes the tag → "get_weather"
forwards:      get_weather        ← the name Backend A actually recognizes
```

If the gateway didn't remove it, Backend A would receive `serverA_get_weather`, find no tool by that name, and return an error. Removing the tag is what makes the routed call work.

### 2. Why "rewrite the body" is a big deal

The tool name lives *inside* the JSON body, not in an outside label. So removing the tag means editing the message body as it flows through, which is harder than just setting a label. It is exactly why an earlier review ruled out the native filter (it could read the body but not change it). It can change it now.

### 3. Discovery vs. doing

`tools/list` (what's available) happens occasionally. `tools/call` (do the thing) is the frequent, time-sensitive path. The investigation cares about two things: not slowing down the common call, and not making discovery expensive.

### 4. Sessions

A conversation with a backend often spans several requests. The gateway keeps a *session*: a thread that ties those requests together, and links the agent's session to each backend's session. Who keeps that thread, and how, is one of the open questions.

### 5. Elicitation

Sometimes a tool needs to ask the user a follow-up in the middle of a call: "which account did you mean?" Getting that follow-up back to the right backend is fiddly and stateful, and it is one of the jobs that stays custom.

### 6. "Native vs. broker": what is being compared

"Native" means the built-in Envoy filters. "Broker" (or "ext-proc") means the current custom gateway code. The whole investigation is one question: **how much can move from the custom code to the built-in filters, and what has to stay?**

---

## Required reading

| Resource | Why |
|---|---|
| [MCP specification](https://modelcontextprotocol.io/specification) | the wire protocol the whole investigation is about |
| [Envoy native MCP filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/mcp_filter) | the filter being evaluated |
| [ext_proc filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_proc_filter) | what it replaces |
| [Kuadrant/mcp-gateway#809](https://github.com/Kuadrant/mcp-gateway/issues/809) | the original issue defining the investigation scope |
| [CONNLINK-1026](https://redhat.atlassian.net/browse/CONNLINK-1026) | the operational evaluation adding the caching and latency layer |

---

## Mini-glossary

| Term | In plain words |
|---|---|
| **ext-proc** | The separate helper program Envoy hands MCP work to today |
| **filter chain** | The line of small steps a request passes through inside Envoy |
| **mcp_filter / mcp_router** | The new built-in steps: the reader and the router |
| **prefix / delimiter** | The `serverA_` tag added to tool names; the `_` (or `__`) between tag and name is the delimiter |
| **fan-out / aggregate** | Asking all backends and combining their answers into one |
| **dynamic metadata** | The details the reader leaves for later steps to use (instead of outside labels or headers) |
| **session** | The thread that ties a multi-message conversation together |
| **elicitation** | A backend asking the user a follow-up mid-call |
| **Authorino** | The allow/deny permission checker |
| **Istio** | The production system that runs Envoy across a cluster; it ships a fixed Envoy version |
| **Gateway API / HTTPRoute / AuthPolicy** | Config pieces that attach routing and permission rules to backends |
| **MCPVirtualServer** | The gateway feature that shows different users a different subset of tools |
| **SSE (server-sent events)** | A way to stream a response back piece by piece instead of all at once |
