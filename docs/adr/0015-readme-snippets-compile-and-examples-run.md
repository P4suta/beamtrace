<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0015 — README snippets compile and examples run in CI

Status: Accepted · 2026-09-01

## Context

The core README's facade example did not compile (missing imports, a top-level `case`), and nothing could catch that: `test-docs.ps1` only greps for marker strings. `fixtures/hex_consumer.gleam` was the sole compile-checked sample, unlinked from the README, and there was no `examples/` directory.

## Decision

- Every Gleam code block in `packages/beamtrace_core/README.md` is a complete module depending only on `beamtrace_core` and the standard library. `scripts/extract-readme-snippets.mjs` extracts the fences and `scripts/test-core-snippets.ps1` (in `test-all.ps1`, after the consumer gate) compiles them in an isolated path-dependency project on both targets — the same pattern as `test-core-consumer.ps1`.
- Runnable examples live at the repository root in `examples/<name>/` (outside the Hex package): `decode_and_compare`, `build_events`, `query_language`, `diagnostics_thresholds`. The gate runs each on both targets and compares the last output line against a pinned expectation, like the consumer gate does. Manifests are committed to pin dependencies.
- The README links the examples and `fixtures/hex_consumer.gleam`.

## Consequences

A README edit that breaks compilation, or a core change that alters example behaviour, fails CI in the same change. Prose keeps showing focused fragments only where they are also part of a complete module in the same block.
