<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0005 — The JSON result envelope stays at schema_version 1 and grows additively

Status: Accepted · 2026-08-30

## Context

`--json` emitted `{schema_version, command, ok, exit_code, artifact, outcome, error}` but `command` echoed whatever the user typed on a parse error, `doctor` returned a stringified report, `path` was relative for `record` and absolute for `demo`, exit codes were scattered literals, and nothing described the object for automation.

## Decision

Keep `schema_version: 1` and extend only additively: `command` is a closed set (specified names, `config check`, `unknown`); `ok` is true exactly when `error` is null and `exit_code` carries the outcome (1 = difference or child exit status, 3 = capture integrity); file artifacts carry `path` and `absolute_path`; `doctor` adds `checks` (`{ok, hint?}` per check); errors may carry `detail`. `schemas/beamtrace-cli-v1/envelope.schema.json` is generated from the specification and the error catalogue, tested against both, and enforced on real outputs by `scripts/check-cli-envelope.mjs` in the smoke gate.

## Consequences

Existing consumers keep working; new consumers can validate every result. Changing the meaning of an existing key requires `schema_version: 2` and a new schema file.
