#!/usr/bin/env python3
"""
mock_mcp_server.py - a small, controllable MCP backend that speaks MCP over HTTP.

Deliberately small so you can read it in one sitting and see exactly what an
MCP server does on the wire. Implements just enough of the protocol for the
Envoy native MCP filter to parse it and for the test lanes to run:

  - initialize        (with an optional startup delay  -> test V3)
  - tools/list        (tool names are prefixed per server -> test C3)
  - tools/call        (returns instantly                 -> test V4 latency)
  - tools/list_changed notifications over SSE (optional   -> test V2)

Everything is configured with environment variables, so you run the SAME script
twice with different settings to get two distinct backends (A and B).

  MCP_NAME                 prefix for tool names + serverInfo name   (default "server")
  MCP_PORT                 port to listen on                         (default 9000)
  MCP_TOOL_COUNT           how many tools to advertise               (default 3)
  MCP_INIT_DELAY           seconds to sleep on `initialize`          (default 0)   -> V3
  MCP_LIST_CHANGED_EVERY   seconds between tools/list_changed pushes  (default 0=off) -> V2

It also records the last `Authorization` header it was sent (the broker presents a
per-server credential there) and exposes it at GET /__stats as `seen_auth` -> test V6.

Run directly:
  MCP_NAME=server1 MCP_PORT=9001 python3 mock_mcp_server.py

No third-party dependencies - Python 3 standard library only.
"""

import json
import os
import threading
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Per-method request counter - lets the V-tests measure how often the gateway
# actually hits this backend (e.g. does `tools/list` get cached, or fanned out
# every time?). Read it at GET /__stats ; clear it at GET /__reset.
_counts = Counter()
_counts_lock = threading.Lock()

# Last `Authorization` header this backend received from whoever connected to it
# (the broker presents a per-server credential here - see test V6). Exposed at /__stats.
_seen_auth = {"value": None}
_auth_lock = threading.Lock()

NAME = os.environ.get("MCP_NAME", "server")
PORT = int(os.environ.get("MCP_PORT", "9000"))
TOOL_COUNT = int(os.environ.get("MCP_TOOL_COUNT", "3"))
INIT_DELAY = float(os.environ.get("MCP_INIT_DELAY", "0"))
LIST_CHANGED_EVERY = float(os.environ.get("MCP_LIST_CHANGED_EVERY", "0"))


def tools():
    """The tools this backend advertises - with PLAIN names (tool1, tool2, ...),
    exactly like a real MCP server that knows nothing about the gateway. Both
    backends deliberately use the same names so they collide; the gateway is what
    adds a per-server prefix (server1__tool1) to disambiguate them. That collision
    is the whole point of test C3."""
    out = []
    for i in range(1, TOOL_COUNT + 1):
        out.append({
            "name": f"tool{i}",
            "description": f"Mock tool {i} on {NAME}",
            "inputSchema": {"type": "object", "properties": {}},
        })
    return out


def handle_rpc(msg):
    """Turn one JSON-RPC request into a JSON-RPC response.
    Returns None for notifications (messages with no `id`)."""
    method = msg.get("method")
    msg_id = msg.get("id")

    # Notifications have no id and expect no response.
    if msg_id is None:
        return None

    if method == "initialize":
        if INIT_DELAY > 0:
            # Simulate a slow backend. With eager init, this blocks every client (V3).
            time.sleep(INIT_DELAY)
        # Echo back the client's protocol version so we don't fight over versions.
        proto = (msg.get("params") or {}).get("protocolVersion", "2025-03-26")
        return {
            "jsonrpc": "2.0", "id": msg_id,
            "result": {
                "protocolVersion": proto,
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": NAME, "version": "0.0.1-mock"},
            },
        }

    if method == "ping":
        # The mcp-gateway broker health-checks upstreams with `ping`; an empty
        # result means "alive". Without this the broker drops our tools.
        return {"jsonrpc": "2.0", "id": msg_id, "result": {}}

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": tools()}}

    if method == "tools/call":
        called = (msg.get("params") or {}).get("name", "?")
        return {
            "jsonrpc": "2.0", "id": msg_id,
            "result": {"content": [{"type": "text", "text": f"{NAME} ran {called}"}],
                       "isError": False},
        }

    # Anything we don't implement: a clean "method not found".
    return {"jsonrpc": "2.0", "id": msg_id,
            "error": {"code": -32601, "message": f"method not found: {method}"}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep stdout clean; the experiments care about Envoy's stats, not these

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""
        try:
            msg = json.loads(body or b"{}")
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        if method := msg.get("method"):
            with _counts_lock:
                _counts[method] += 1
        # Record the credential the caller presented (broker -> upstream auth, V6).
        auth = self.headers.get("Authorization")
        if auth:
            with _auth_lock:
                _seen_auth["value"] = auth

        resp = handle_rpc(msg)
        if resp is None:
            # Notification - acknowledge with 202 and no body.
            self.send_response(202)
            self.end_headers()
            return

        payload = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        # Test instrumentation: per-method request counts, and a reset.
        if self.path == "/__stats":
            with _counts_lock, _auth_lock:
                payload = json.dumps({"server": NAME, "counts": dict(_counts),
                                      "seen_auth": _seen_auth["value"]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/__reset":
            with _counts_lock:
                _counts.clear()
            with _auth_lock:
                _seen_auth["value"] = None
            self.send_response(200)
            self.end_headers()
            return

        # MCP servers push notifications to the client over an SSE stream.
        if "text/event-stream" not in self.headers.get("Accept", ""):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"{NAME} mock MCP server - POST JSON-RPC here\n".encode())
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            while True:
                if LIST_CHANGED_EVERY > 0:
                    note = {"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}
                    self.wfile.write(f"data: {json.dumps(note)}\n\n".encode())
                    self.wfile.flush()
                    time.sleep(LIST_CHANGED_EVERY)
                else:
                    time.sleep(1)  # hold the stream open, send nothing
        except (BrokenPipeError, ConnectionResetError):
            return  # client went away


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    knobs = f"tools={TOOL_COUNT} init_delay={INIT_DELAY}s list_changed_every={LIST_CHANGED_EVERY}s"
    print(f"[{NAME}] MCP mock listening on :{PORT}  ({knobs})", flush=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        print(f"[{NAME}] shutting down", flush=True)


if __name__ == "__main__":
    main()
