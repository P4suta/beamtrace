<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0011 — Core vocabulary is finalized before the first stable release

Status: Accepted · 2026-09-01

## Context

The next release is deferred indefinitely, so `beamtrace_core` has one chance to fix naming debt without a compatibility tail: two constructor names collide across modules (`Metric`, `SystemSignal`), `Mfa` leaks trailing-underscore labels, `TermView` mixes naming schemes, and `beamtrace.prepare`/`diff.prepare` share a name with different behaviour. ADR 0006 keeps deprecated APIs for one release, which only helps published consumers.

## Decision

- Because nothing after 0.2.0 is published, deprecated APIs are deleted now instead of retiring over a release: `diff.compare` (unchecked wrapper) is removed and `diff.compare_checked` takes the `compare` name; `aql.compile_agent`/`AgentPlan` are removed in favour of `compile_trigger`.
- Renames, wire format untouched: `anomaly.Metric` → `MetricKind`, `anomaly.SystemSignal` → `VmSignal` (`from_vm_signal`), `types.Mfa(module:, function:)` drops the underscores (both are legal Gleam labels), `types.TermView.Tag` → `TagOnly` (only the tag survived redaction), `ListView`/`MapView` → `BoundedList`/`BoundedMap`. `Tuple`, `Constructor`, and `Atom` mirror Erlang concepts and stay.
- The facade accessor `beamtrace.prepare` becomes `prepared`: accessors are nouns (`events`, `graph`), failable constructors are verbs (`diff.prepare`).
- `merge.bounds`' `Result(_, String)` is not an error type: the string is `TimeUnavailable.reason` passed through as data, so the one-renderer rule of ADR 0006 does not apply.
- The interface snapshot moves to `test/package-interface-v0.4.json`; old-name → new-name pairs are recorded in `docs/migration-v0.4.md`.

## Consequences

Both import collisions disappear; every remaining public name states its meaning without suffix conventions. Path-dependent packages, fixtures, and the two performance-gate escripts were updated in the same change (`'beamtrace@diff':compare/2` now returns `{ok, Report}`).
