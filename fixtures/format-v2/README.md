<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Format v2 golden documents

Files under `valid` are canonical byte representations accepted by the corresponding BeamTrace codec. Files under `invalid` exercise unknown versions/fields, removed confidence shapes, unsafe relative time, incomplete full serials, noncanonical JSON, and invalid clock bounds.

Archive-level corruption (checksum injection/extra entries, duplicate paths, noncontiguous segments, graph reference mismatch, and atomic replace failure) is generated in runtime security tests because those cases require a ZIP container or controlled filesystem failure.
