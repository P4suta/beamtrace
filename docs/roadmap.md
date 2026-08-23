<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Roadmap and implementation status

## Implemented in the current alpha

- dependency-free injected agent, isolated trace session, meta trigger, exact cleanup
- shortname/longname single- and multi-node capture with partial-order events
- metadata shaping, budgets, credit flow, truncation and gap semantics
- canonical event codec, AQL parsing/evaluation, causal DAG, identity, diagnostics, anomaly, diff
- CLI capture/open/compare/export/doctor/record and HTTPS relay enrollment
- safe segmented `.beamtrace`, paged reader/API, HTML/JSONL/Mermaid/OTLP exports
- bounded Live process sampling without mailbox contents
- Web workspace, Canvas window, accessible event table and inspector
- TUI attach/arm/search/save interaction model
- OIDC discovery/callback verification, CSRF, RBAC, and team HTTP middleware
- SQLite WAL metadata/index schema, filesystem blobs, event-aware quotas, startup retention, and audit-chain contracts
- persistent signed outbound relay WebSocket, one-time Ed25519 enrollment, credit-based batches, and canonical metadata privacy validation
- relay producer capture from attached target nodes, including bounded audited raw grants
- shared live-session fan-out and full multi-trace visual Compare workspace
- HTTPS S3-compatible SigV4 blobs with conditional writes, verified reads, retention, and real MinIO TLS acceptance
- indexed search over unloaded segments and PID/clock-independent multi-run p50/p95/occurrence statistics
- real Chromium acceptance over one million logical events, keyboard/axe checks, PTY harness, and package smoke tests
- self-contained native archive packaging with bundled ERTS and SQLite NIF, SPDX SBOM/checksums, OCI image, Hex tarball, Homebrew/Scoop metadata, and GitHub release provenance

## Post-alpha release operations

- publish source-repository-specific Homebrew tap and Scoop bucket metadata when those repositories exist
- configure the repository-scoped release App and short-lived Hex credential before approving the first release PR
- review all five supported native archive candidates on the release PR; merging that PR is the sole publication approval
- add Windows ARM64 packaging once CI can build or provision a reproducible native Erlang/OTP runtime without relabeling an x64 runtime

Runtime features stay listed as implemented only after an acceptance test exercises the real boundary. A type or pure policy module alone does not mark an integration complete.
