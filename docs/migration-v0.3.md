<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Migrating to BeamTrace 0.3

BeamTrace 0.3 changes the causal and time contracts. Existing `.beamtrace` schema v1 archives remain readable, but every new save and explicit migration writes schema v2.

## Archive migration

```text
beamtrace validate old.beamtrace --json
beamtrace migrate old.beamtrace --output migrated.beamtrace
beamtrace validate migrated.beamtrace --json
```

The output path must differ from the input path. Migration never edits or deletes the source. V1 absolute node timestamps are normalized to node-relative offsets and arrival-order tie breakers. V1 message serials become `LegacySerial(current)` because the missing previous counter cannot be recovered. V1 completeness and confidence values become `legacy_unknown`/`legacy_unverified` warnings; confidence is not copied into v2.

Migrated v1 archives do not acquire clock calibration. Cross-node durations and OTLP Unix timestamps therefore remain unavailable. OTLP export rejects them by default; `--otlp-anchor-now` explicitly chooses a synthetic export anchor and emits a warning.

## API migration

New integrations should use `/api/v2`. Event time is returned as exact, estimated `{value,lower,upper}`, or unavailable. Graph edges and boundaries come from the API and must not be reconstructed from adjacent rows. Capture status returns the structured outcome, clock calibration, and derived `delivery_verified` flag.

`/api/v1` remains a deprecated adapter for one release. It can emit a v1 event only when calibrated time is a point and evidence is exact. Otherwise it returns an explicit projection error; it never drops uncertainty or invents a confidence number.

## Agent and relay migration

The injected agent protocol is v2: every batch carries its node and sequence, and seal returns a final receipt after trace-session and seq_trace delivery barriers. Collectors record gaps, duplicates, receipt mismatches, missing nodes, and drain timeouts as issues.

New Team relay sessions use protocol v3 and declare event schema v2. Relay protocol v2 is accepted only as migration input. Team transfer state is named `delivery_status`; it is independent of the causal capture outcome inside an archive.

## CLI safety change

Attach-mode exact capture uses the VM-global seq_trace system tracer and resets seq_trace during cleanup. Scripts must pass `--acknowledge-seq-trace-reset` after presenting that impact to the operator. `record` starts a separate VM and acknowledges this isolation automatically. An occupied system tracer is still refused and never overwritten.

## Library and CLI contracts

- `beamtrace_core`: `diff.prepare` returns `Result(PreparedTrace, DagError)`; `diff.compare` and `aql.compile_agent` are deprecated in favour of `diff.compare_checked`/the `beamtrace` façade and `aql.compile_trigger`; `codec.event_v1_adapter_json` is internal.
- CLI `--json` keeps `schema_version: 1` and adds `absolute_path`, `doctor.checks`, and `error.detail`; see `schemas/beamtrace-cli-v1/envelope.schema.json`.
- Human errors print `beamtrace[E_<CODE>]` with the same code and hint as `--json`; the exit-derived labels `E_COMMAND_FAILED`, `E_CAPTURE_INTEGRITY`, and `E_SAFETY_REFUSAL` remain only for uncatalogued failures.
