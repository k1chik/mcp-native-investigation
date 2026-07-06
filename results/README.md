# Results

Captured output from `./run-tests.sh`. Each file is one lane run — raw terminal output
plus a header with the date, Envoy version, and platform so the run is reproducible.

To reproduce any result, run the matching lane from the repo root:

```bash
./create-env.sh          # one-time: checks tools, pulls images
./run-tests.sh c1-c3-c4a
```

## Runs

| File | Lane | Date | Result |
|---|---|---|---|
| [c1-c3-c4a.txt](c1-c3-c4a.txt) | C1, C3, C4a | 2026-06-09 | PASS |
| [c2.txt](c2.txt) | C2 | 2026-06-10 | PASS |
| [c4b.txt](c4b.txt) | C4b | 2026-06-10 | PASS |
| [c5.txt](c5.txt) | C5 | 2026-06-13 | PASS |
| [c5-kuadrant.txt](c5-kuadrant.txt) | C5/kuadrant (full Kuadrant stack, real Authorino) — run `tests/capability/c5/kuadrant/smoke.sh` after `tests/capability/c5/kuadrant/create-env.sh` | 2026-07-06 | PASS |
| [c6.txt](c6.txt) | C6 (Istio 1.30 + Kuadrant AuthPolicy) — run `tests/capability/c6/smoke.sh` after `tests/capability/c6/create-env.sh` | 2026-07-06 | BLOCKED |
| [v1-v3-v4.txt](v1-v3-v4.txt) | V1, V3, V4 | 2026-06-13 | PASS |
| [v2.txt](v2.txt) | V2 | 2026-06-13 | PASS |
| [v6.txt](v6.txt) | V6 | 2026-06-13 | PASS |
