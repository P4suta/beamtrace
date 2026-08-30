<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Reading BeamTrace results

Start with the evidence overview, not the event count.

## Observation end

The end states why recording stopped: quiet period, time window, user stop,
budget, or agent failure. A quiet period starts sealing; it is not a claim that
unobserved work does not exist.

## Delivery verification and issues

Delivery is verified only when final node receipts agree and no integrity issue
is present. Drops, missing nodes, batch gaps, duplicate batches, receipt
mismatches, and drain timeouts remain explicit. Re-run the operation after
fixing the named node or transport problem; do not reinterpret a partial result
as complete.

## Boundaries

A boundary marks causal evidence BeamTrace cannot cross, such as ports,
external I/O, an unobserved process, or legacy data. Events on either side are
still useful, but the trace does not establish the missing relationship.

## Exact and Inferred

`Exact` means the relation was present in captured trace metadata. `Inferred`
always names its method, reason, evidence events, observed values, and settings.
It is a reproducible claim, not a probability.

## First divergence

Node-local order is exact only within its node. Cross-node calibrated time is
an interval and can be unavailable. Compare aligns logical actor and causal
shape, reports missing samples, and preserves ambiguous regions. “First
divergence” is shown only when the checked alignment establishes one.
