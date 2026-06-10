# Results

Captured output from `./run-tests.sh`. Each file is one lane run - raw terminal output
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
