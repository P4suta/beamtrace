<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0016 — The CLI error catalogue is closed

Status: Accepted · 2026-09-01

## Context

ADR 0003 centralized CLI failures in `cli_errors`, but `cli_lifecycle` still emitted fourteen ad-hoc codes — nine through a private `emit_json_error` and five through direct `CliError` construction. They were absent from the envelope schema enum, `beamtrace help errors`, and the reference table, and `init`/`config`/`doctor` failures reported different codes on the human and JSON channels, breaking ADR 0003's one-catalogue promise.

## Decision

- Every CLI failure is constructed by a `cli_errors` catalogue function. `emit_json_error` is deleted; direct `CliError(...)` construction outside `cli_errors` is forbidden and a test rejects both patterns in `cli_lifecycle`.
- The fourteen codes join the catalogue (31 → 45): `unsupported_json_command`, `configuration_create_failed`, `invalid_configuration`, `cookie_unavailable`, `export_conversion_failed`, `export_write_failed`, `demo_fixture_unavailable`, `invalid_paths`, `trace_load_failed`, `target_node_unavailable`, `capture_arm_failed`, `child_release_failed`, `child_shutdown_failed`, `child_wait_failed`. Variable context (paths, config reasons) travels in `detail`, keeping messages stable.
- Adding a code to the `error.code` enum is an additive schema_version 1 change (ADR 0005). Consumers must treat unknown codes as a generic failure of the reported exit class rather than rejecting the envelope.
- Human and JSON channels report the same code for the same failure; `init`, `config check`, and `doctor` now go through the catalogue on both.

## Consequences

`beamtrace help errors`, the reference table, and the schema enum stay complete automatically — existing tests compare all three against `cli_errors.codes()`, and the smoke suite exercises negative `--json` paths against the schema.
