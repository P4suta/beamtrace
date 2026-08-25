<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# BeamTrace v2 conformance

A conforming writer emits only schema v2, the exact archive entry allowlist, canonical JSON/NDJSON, paired event/graph segments, canonical indexes and annotations, and an ordered checksum record covering every other entry.

A conforming reader dispatches on `manifest.json.schema_version` before interpreting other entries. It rejects unknown versions and fields, noncanonical JSON, unsafe or duplicate ZIP paths, excessive expansion, noncontiguous segments, invalid IDs/MFAs/relative time/serials, invalid graph references or cycles, malformed calibration, and every checksum-set or digest mismatch.

Run the repository conformance gate with:

```powershell
pwsh -File scripts/test-format-conformance.ps1
```

The gate validates the JSON documents under `fixtures/format-v2/valid`, rejects every document under `fixtures/format-v2/invalid`, then runs archive golden, v1-read, v1-to-v2 migration, checksum-injection, graph-reference, and atomic-replace tests in `beamtrace_runtime`.

Implementations should also verify:

- no absolute nanosecond value enters browser integer fields;
- a full `{previous,current}` serial is required for exact message pairing;
- cross-node ordering is never inferred from clock centers;
- estimated time retains both bounds;
- a verified outcome has matching nonempty receipts and no issues;
- graph rendering uses only declared edges and boundaries.

The JSON Schemas are a structural aid, not a substitute for canonical-byte, graph, checksum, and cross-entry validation.
