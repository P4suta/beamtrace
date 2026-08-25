<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# `.beamtrace` format v2

`.beamtrace` is a hostile-input ZIP container. Version dispatch is performed from `manifest.json` before any version-specific entry is interpreted. BeamTrace 0.3 writes only schema v2; schema v1 is read-only migration input.

## Canonical entry set

```text
manifest.json
events/000001.ndjson
graph/000001.json
clocks.json
indexes/events.idx
annotations.json
checksums.json
```

Event and graph segments are contiguous six-digit sequences. Every event segment has exactly one graph segment with the same number and boundary. Non-final event segments contain exactly 1,000 canonical JSON lines; the final segment contains 0–1,000. An empty capture still has `events/000001.ndjson` and `graph/000001.json`.

`manifest.json` records schema/tool versions, capture ID, observed nodes, privacy policy, and a structured `CaptureOutcome`. The outcome separates the observation end (`quiet_period`, `time_window`, `user_stopped`, `budget_reached`, `agent_failure`, or `legacy_unknown`) from integrity issues and per-node final receipts. `delivery_verified` is derived only when the issue list is empty and at least one receipt exists; it is not stored as a claim.

Each event stores `LocalInstant {offset_ns, order}`. Both values are non-negative JavaScript-safe integers relative to node-local origins. Within one node they are compared lexicographically, with monotonic `offset_ns` first and strict trace `order` only as its tie breaker. Collector mailbox arrival order is not causal. Full seq_trace identifiers are `{previous,current}`; a migrated v1 value is tagged `legacy` and cannot establish an exact edge when it collides.

Evidence is either `{"kind":"exact"}` or a structured inference containing `method`, `reason`, and bounded inputs. Inputs identify evidence events, observed values, and algorithm settings. Schema v2 has no confidence field.

Each `graph/NNNNNN.json` lists that event segment's IDs, real process/message/spawn edges touching the segment, and open boundaries. A loader rebuilds the graph from events and requires byte-decoded graph content to equal the expected segmentation; nonexistent IDs, invented adjacency edges, and cycles are rejected.

`clocks.json` contains the capture Unix anchor and, per node, the local origin plus optional before/after minimum-RTT samples. Unix and monotonic clock values are decimal strings so JavaScript never parses absolute nanoseconds as IEEE-754 integers. Uncertainty and RTT remain explicit. Missing either phase makes cross-node time unavailable.

`indexes/events.idx` is canonical and maps each event segment to its first global index and count. `annotations.json` is currently the canonical empty v2 document; annotations remain a separately versioned extension point.

`checksums.json` has exactly `algorithm` and `files`. `algorithm` is `sha256`; `files` has one ordered `{path,sha256}` object for every other allowed entry and no duplicates. Digests are exactly 64 lowercase hexadecimal characters. Missing, additional, reordered, duplicated, injected, or mismatched entries fail validation.

## Validation and limits

V2 JSON objects must match BeamTrace's canonical byte encoding. Unknown fields, alternate key order, insignificant whitespace, duplicate object members that do not round-trip canonically, invalid IDs/nodes/MFAs, invalid serials or local instants, excessive collections, invalid graph references, and malformed clock samples are rejected with typed codec/storage errors.

Container limits are 10,000 entries, 1 GiB total expanded bytes, 64 MiB per entry, and a 200:1 suspicious-compression threshold for entries above 1 MiB. Absolute paths, parent traversal, empty path segments, backslashes, drive prefixes, NULs, directory entries, duplicate names, non-contiguous segments, and any entry outside the schema's exact allowlist are rejected before use.

Saving uses a sibling temporary ZIP, syncs it, and atomically renames it over the destination. The destination is never unlinked first; a failed replace preserves the previous archive.

## Tools and schemas

- `beamtrace validate FILE --json` performs container, canonical JSON, checksum, graph/reference, and clock validation.
- `beamtrace migrate SOURCE --output DESTINATION` reads v1 or v2 and writes a distinct v2 archive without modifying the source. V1 confidence values are discarded with a `legacy_unverified` warning, not reinterpreted as probabilities.
- Machine-readable schemas live in [`schemas/beamtrace-v2`](../schemas/beamtrace-v2), with valid and invalid examples in [`fixtures/format-v2`](../fixtures/format-v2).

See [migration-v0.3.md](migration-v0.3.md) for compatibility behavior and [conformance.md](conformance.md) for the acceptance corpus.
