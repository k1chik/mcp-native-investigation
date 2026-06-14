# V6 — Per-backend auth

Proves the broker presents a **distinct credential per backend** on its own upstream
connection. The client's auth header is not involved — this is purely broker→upstream auth.

## What this lane checks

| ID | What it measures | CONNLINK-1026 |
|----|-----------------|---------------|
| V6 | Broker presents `Authorization: cred-server1-AAA` to backend-a and `Authorization: cred-server2-BBB` to backend-b. Native `mcp_router` forwards the client's headers uniformly — no per-backend credential model. | Craig Brookes concern #5: per-backend auth |

## Prerequisites

- `docker`
- `python3`

## How to run

```bash
docker compose up -d
./run-v6.sh
docker compose down
```

## Expected output

```
########  V6 — per-backend auth: broker presents distinct creds  ########
  backend-a (server1) received from broker: Bearer cred-server1-AAA
  backend-b (server2) received from broker: Bearer cred-server2-BBB

  V6 PASS — each backend received its OWN distinct credential from the broker.
            server1 <- cred-server1-AAA  |  server2 <- cred-server2-BBB
            Native mcp_router has no equivalent — it forwards the client's
            headers uniformly to all backends (no per-backend broker credential).
```

## Key finding

The broker reads a `credential` field per server in `config.yaml` and presents it as
`Authorization: <credential>` on its own connection to that upstream during
`initialize`, `tools/list`, and `ping`. Each backend sees only its own credential.

Native `mcp_router` has no equivalent. It forwards whatever headers the client sent
to every backend uniformly — there is no per-backend broker-credential concept. Adding
per-backend static headers in Envoy cluster config is possible but hand-rolled and
doesn't integrate with Kuadrant's secret management model.

## Architecture

```
run-v6.sh (curl)
    -> broker :8080  (reads config.yaml: server1=cred-AAA, server2=cred-BBB)
        -> backend-a (server1) :9001  receives Authorization: Bearer cred-server1-AAA
        -> backend-b (server2) :9002  receives Authorization: Bearer cred-server2-BBB

GET /__stats -> seen_auth on each backend confirms the credential it received
```

The broker image is `ghcr.io/kuadrant/mcp-gateway:v0.7.0` (publicly available).
No Kubernetes, no Istio — the broker runs as a standalone container.
