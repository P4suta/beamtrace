<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Migrating to BeamTrace 0.4

This page records every `beamtrace_core` contract change since 0.3 as an
old → new pair. The wire format (schema-v2 archives, relay protocol v2, CLI
JSON envelope) is unchanged unless a row says otherwise.

## Renamed or removed core API

| 0.3 | 0.4 | Notes |
| --- | --- | --- |
| `diff.compare(left, right) -> DiffReport` | removed | The unchecked fallback is gone; there is no silent comparison of an invalid trace. |
| `diff.compare_checked(left, right)` | `diff.compare(left, right)` | Same behaviour: `Result(DiffReport, dag.DagError)`. |
| `aql.compile_agent`, `aql.AgentPlan` | removed | Use `aql.compile_trigger`, which returns the executable `TriggerPlan`. |
| `beamtrace.prepare(trace)` | `beamtrace.prepared(trace)` | O(1) accessor; `diff.prepare` (failable) keeps its name. |
| `types.Mfa(module_:, function_:, arity:)` | `types.Mfa(module:, function:, arity:)` | Label rename only. |
| `types.TermView.Tag(name)` | `types.TermView.TagOnly(name)` | Encoded tag `"tag"` unchanged. |
| `types.TermView.ListView(length:, items:)` | `types.TermView.BoundedList(length:, items:)` | Encoded tag `"list"` unchanged. |
| `types.TermView.MapView(size:, entries:)` | `types.TermView.BoundedMap(size:, entries:)` | Encoded tag `"map"` unchanged. |
| `anomaly.Metric` | `anomaly.MetricKind` | No longer collides with `types.Metric`. |
| `anomaly.SystemSignal` | `anomaly.VmSignal` | No longer collides with `types.SystemSignal`. |
| `anomaly.from_system_signal` | `anomaly.from_vm_signal` | Rename only. |

## Behavioural notes

- `beamtrace.event_count` is now O(1).
- Erlang callers of `'beamtrace@diff':compare/2` receive `{ok, Report}` or
  `{error, DagError}` instead of a bare report.

See `docs/adr/0011-core-vocabulary-finalized-before-first-stable-release.md`
for the rationale.
