<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0006 — Public surface policy for beamtrace_core

Status: Accepted · 2026-08-30

## Context

`beamtrace_core` is published to Hex and consumed on Erlang and JavaScript. Its interface snapshot (`test/package-interface-v0.3.json`) is byte-compared in CI, so every public change is deliberate, but the package had no rule for what is public, how compatibility APIs retire, or where error rendering lives.

## Decision

- `@internal` marks items that exist only for the runtime's one-release compatibility adapters (`codec.event_v1_adapter_json`); they stay callable by path dependencies but leave hexdocs and the interface. `internal_modules = ["beamtrace/internal/*"]` is reserved for future internal modules.
- Structured JSON builders (`codec.*_json`) and `codec.decode_event_structural` stay public: consumers embed events in their own documents and implement protocol boundaries.
- Compatibility APIs are kept for one release with `@deprecated(...)` naming the replacement (`diff.compare`, `aql.compile_agent`); the runtime builds with `--warnings-as-errors` and therefore never uses them.
- Every error type has exactly one renderer in the module that defines it (`codec.error_message`, `dag.error_message`, `mfa.error_message`, `beamtrace.error_message`); other packages derive machine codes, never prose.
- The interface snapshot is regenerated in the pull request that changes the surface, and the JSON diff is listed in the PR description.

## Consequences

Consumers see a smaller, consistently documented surface; the doc-coverage checker covers type aliases; deprecated calls warn at compile time and disappear in the next minor release.
