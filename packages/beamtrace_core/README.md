<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# beamtrace_core

Target-independent causal trace contracts and analysis for the BeamTrace BEAM causal workbench.

This package contains the portable Gleam data model used by Erlang and JavaScript clients. It does not attach to a BEAM node or enable tracing by itself.

## Installation

Add the package to a Gleam project:

```sh
gleam add beamtrace_core
```

API documentation is generated at [hexdocs.pm/beamtrace_core](https://hexdocs.pm/beamtrace_core/). The source for each documented definition links back to the `packages/beamtrace_core` path in the BeamTrace monorepo.

## Modules

- `beamtrace/types` — capture specifications, trace events, evidence, completeness, and privacy-safe term views
- `beamtrace/aql` — parsing, evaluation, and safe agent-side planning for BeamTrace Query Language
- `beamtrace/dag` and `beamtrace/merge` — causal graph validation and distributed partial-order merging
- `beamtrace/identity` — physical process and logical actor identity evidence
- `beamtrace/anomaly` and `beamtrace/diagnostics` — bounded Live analysis contracts
- `beamtrace/diff` and `beamtrace/stats` — PID-independent alignment and multi-run statistics
- `beamtrace/codec` and `beamtrace/protocol` — versioned trace and wire contracts

Every causal relationship is represented as exact evidence or as an inference carrying a reason and confidence. External boundaries and missing observations remain explicit.

## Compatibility

`beamtrace_core` supports Gleam 1.18 or newer within the 1.x series and compiles for both Erlang and JavaScript targets.

## License

Licensed under either Apache-2.0 or MIT, at your option. Both complete licence texts are included in the package's `LICENSE` file.
