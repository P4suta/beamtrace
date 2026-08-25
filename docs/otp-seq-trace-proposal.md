<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Draft OTP proposal: session-scoped sequential tracing

Status: local design draft for discussion; not submitted upstream.

## Problem

`trace` sessions isolate process/meta tracing, but sequential tracing still relies on the VM-global seq_trace system tracer and global token reset behavior. An attach tool must therefore disclose that it will claim the system tracer and reset sequential trace state during cleanup. Label filtering reduces interference but does not provide ownership, scoped cleanup, or a session delivery barrier.

## Proposed API shape

1. Allow a trace session to own sequential tracing for one opaque lease.
2. Route only selected labels to that session's tracer.
3. Add label-scoped token cleanup that cannot reset unrelated labels.
4. Extend `trace:delivered/2` (or add an equivalent session call) so one barrier covers process/meta and sequential trace messages generated before the barrier.
5. Release the lease automatically when its session is destroyed or owner exits.
6. Return an explicit conflict when another owner holds an overlapping label/lease; never silently replace it.

## Required semantics

- Delivery acknowledgement means all matching trace messages generated before the request have reached the session tracer mailbox.
- Cleanup is idempotent and bounded.
- Labels and leases are unforgeable or ownership-checked.
- Existing `seq_trace` and `erlang:trace_delivered(all)` behavior remains compatible.
- Distributed nodes report barriers independently; no global wall-clock synchronization is implied.

## BeamTrace conformance scenario

Arm a session, generate sequential send/receive events while collector credit is exhausted, initiate seal, generate a concurrent post-seal message, pass the delivery barrier, drain queued batches, and compare the final receipt. Every pre-seal accepted event must be present; post-seal ingestion must be rejected; destroying the session must preserve unrelated tracer state.

This draft intentionally makes no claim that OTP has accepted the design.
