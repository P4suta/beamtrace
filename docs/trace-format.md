<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# `.beamtrace` format

The format is a ZIP container. Readers must treat it as hostile input and validate the central directory before extraction.

```text
manifest.json
events/000001.ndjson
events/000002.ndjson
processes.ndjson
annotations.json
indexes/events.idx
checksums.json
```

`manifest.json` records schema/tool versions, capture ID, nodes, completeness, privacy mode, and logical checksums. Event segments contain at most 1,000 canonical JSON events and are named contiguously. `checksums.json` covers every other entry with SHA-256.

Each event contains a node-local strict timestamp and causal identifiers. No reader may interpret node-local timestamps from different nodes as a total order. Message serials and explicit evidence establish exact edges; inferred edges include a reason and confidence.

Import limits are 10,000 entries, 1 GiB total expanded bytes, 64 MiB per entry, and a suspicious compression ratio threshold. Absolute paths, parent traversal, backslashes, drive prefixes, NULs, directories, duplicate entry names, non-canonical event segments, and checksum failures are rejected.

Schema migrations must be tested with golden containers. Unknown event kinds become explicit gaps or a version error; they must not be silently mapped to a known causal event.
