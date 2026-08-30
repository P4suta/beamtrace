<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0007 — Human time labels are computed from decimal strings

Status: Accepted · 2026-08-30

## Context

The event table showed calibrated time as raw nanoseconds (`1788090105011610338 ns estimated [...]`). Unix nanosecond instants exceed 2^53, so the Web client (JavaScript target) already keeps `value_ns` as a decimal string; parsing it into a number would lose precision.

## Decision

`beamtrace_web/time_format` renders labels by slicing the decimal string into whole seconds and nanoseconds, converting seconds to a civil UTC date with integer arithmetic only, and reporting the interval half-width from the same split. Every label keeps the evidence word (`exact`, `estimated`, `time unavailable · reason`), the estimated interval (`±30.081 µs`), and never rounds away uncertainty. Raw values stay available in the inspector and as a tooltip.

## Consequences

Tables read as `+15.894 ms · 2026-08-30 11:41:45.011610 UTC ±30.081 µs · estimated`; no float formatting differences between targets; malformed values fall back to the raw label rather than failing.
