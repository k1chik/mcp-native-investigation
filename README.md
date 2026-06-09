# mcp-native-investigation

Reproducible evaluation of Envoy's native MCP filter against the mcp-gateway broker.

This investigation is part of the [LFX Mentorship 2026 (Jun-Aug)](https://mentorship.lfx.linuxfoundation.org/project/1acff18b-c4da-4166-9a79-ceb8a8ad112b) program. The project is listed under the [CNCF mentoring program](https://github.com/cncf/mentoring/blob/main/programs/lfx-mentorship/2026/02-Jun-Aug/README.md#investigate-native-envoy-mcp-filter-as-replacement-for-ext-proc-parsing-in-the-kuadrant-agentic-gateway) as: **Investigate native Envoy MCP filter as replacement for ext-proc parsing in the Kuadrant Agentic Gateway**.

---

## What is this

[`Kuadrant/mcp-gateway`](https://github.com/Kuadrant/mcp-gateway) uses an Envoy external processor (`ext-proc`) to handle MCP parsing, routing, and body rewriting. Envoy 1.38 shipped a native MCP filter chain that may be able to replace some or all of that custom code.

This repo contains the prototype, the test harness, and the working notes behind the evaluation. The design recommendation will be submitted as a PR to `Kuadrant/mcp-gateway`.

---

## Contents

| File / Dir | What it is |
|---|---|
| [`PRIMER.md`](PRIMER.md) | Plain-language introduction to the moving parts — start here if Envoy, MCP, or `Kuadrant/mcp-gateway` are new to you |
| [`TESTS.md`](TESTS.md) | Test matrix and status tracker — all capability and operational checks with scope boundary |
| [`create-env.sh`](create-env.sh) | One-script environment setup: checks tools, clones sources, pulls images |
| [`mocks/`](mocks/) | Controllable mock MCP backends used in all test lanes |

---

## Pinned versions

| What | Version |
|---|---|
| Envoy | `v1.38.0` |
| `Kuadrant/mcp-gateway` | `v0.7.0` (commit `5d96c6f`) |
