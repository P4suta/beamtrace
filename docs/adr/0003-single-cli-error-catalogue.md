<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0003 — One CLI error catalogue for human and JSON output

Status: Accepted · 2026-08-30

## Context

Human errors derived a label from the exit code alone (five labels, one generic hint), while `--json` emitted ad-hoc `code`/`hint` strings at each call site. The same failure produced different guidance in the two channels, missing files were reported as invalid archives, and raw Erlang reasons such as `arm_timeout` reached users.

## Decision

`beamtrace_runtime/cli_errors` owns every user-facing failure as `CliError(code, exit, message, hint, detail)` plus the `ExitCode` enum (0, 1, 2, 3, 4, 130, 143). Human output renders `beamtrace[E_<UPPER(code)>]: message`, an optional indented `Child output (tail)` detail, and `Next: hint`; JSON emits the same fields (`detail` is additive). Capture reasons and storage errors are translated by `from_capture_reason` and `from_storage`; unknown reasons go to `detail`, never to `message`. `fail(message, exit)` remains only as a bridge (`legacy`) for call sites not yet migrated.

## Consequences

`beamtrace help errors` and the CLI reference are generated from the catalogue and tested against it. New failure modes are added in one place and appear identically in both channels.
