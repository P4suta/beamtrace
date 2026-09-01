<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0014 — Diagnostic thresholds are explicit records

Status: Accepted · 2026-09-01

## Context

`beamtrace.findings` hardcoded its thresholds (100 messages/senders, 100 ms, 1 s) and silently omitted `dangling_calls`, which needs a capture outcome and reference time. Changing one threshold meant abandoning the facade for five separate `diagnostics` calls.

## Decision

- `diagnostics.Thresholds` names every analysis threshold in one record; `default_thresholds()` carries the documented defaults (plus 5 s for dangling calls). Partial adjustment uses record-update syntax — no builder, no options list.
- `diagnostics.analyze(events, thresholds:)` composes the four capture-independent analyses; `analyze_capture(events, thresholds:, outcome:, now_ns:)` adds `dangling_calls`. The facade mirrors this split: `findings` (defaults) = `findings_with` (explicit) for validated traces, and `capture_findings` for traces with a verified outcome.
- The dangling-call omission is now structural, not silent: it is visible in the function you choose, and each doc comment says why.

## Consequences

The individual analysis functions stay public for callers who want one analysis; the composed API guarantees ordering (hot senders, fan-in, queue waits, restart chains, then dangling calls).
