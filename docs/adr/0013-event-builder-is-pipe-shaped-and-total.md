<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0013 — The event builder is pipe-shaped and total

Status: Accepted · 2026-09-01

## Context

Constructing one `types.TraceEvent` by hand takes ~20 lines of nested records (`ProcessIdentity` → `ProcessRef`, `LocalInstant`, `SequenceSerial`), and the codec invariant `process.physical.node == event.node` is easy to violate. Consumers producing their own events (tests, adapters, examples) need a concise, safe path.

## Decision

- New module `beamtrace/event`: an opaque `Builder` carries what events repeat — root id, observing process, instant, evidence — with `builder(root:, process:)` defaults of `LocalInstant(0, 0)` and `Exact`, refined by `at(offset_ns:, order:)` and `inferred_by(method:, reason:, inputs:)`.
- One finisher per `TraceEventKind`, named exactly after the constructor (`root`, `send`, `received`, `spawn`, `exit`, `register`, `link`, `metric`, `system_signal`, `gap`, `stop`), each returning a finished `TraceEvent`.
- Finishers return the record directly — no `Result`. Validation stays at the codec and facade boundaries (ADR 0006); the builder instead makes the node invariant unrepresentable by always deriving `node` from the process. A qcheck property pins "built events always satisfy `codec.validate_event`".
- Identity helpers `process(node:, pid:)`, `actor(node:, pid:, id:, label:)`, and `serial(previous:, current:)` flatten the nested records.

## Consequences

The README façade example drops from ~20 lines to 6. Callers who need identity evidence still construct `ProcessIdentity` directly; the builder does not wrap every field of every record.
