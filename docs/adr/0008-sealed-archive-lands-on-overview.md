<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0008 — A sealed archive opens on its result

Status: Accepted · 2026-08-30

## Context

`beamtrace open` and `beamtrace demo` showed a read-only sealed archive beneath the capture arming form (MFA trigger, Arm/Cancel), with the navigator saying "No trigger armed".

## Decision

When the session status is sealed and this client never armed a capture, the workspace opens on an overview (event count, outcome, delivery, save controls, "New capture") and hides the arming form; "New capture" and "Back to result" toggle between the two. A capture armed in this client keeps the form visible while it seals. The navigator reports "Sealed archive · N events".

## Consequences

The first screen answers what was observed; arming remains one click away. The idle attached workspace is unchanged.
