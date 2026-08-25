<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Roadmap and implementation status

## Implemented in the current alpha

- dependency-free injected agent, isolated trace session, meta trigger, exact cleanup
- shortname/longname single- and multi-node capture with partial-order events
- metadata shaping, budgets, credit flow, seal/drain barriers, batch receipts, and explicit integrity issues
- schema-v2 canonical event/outcome/time/evidence codecs, AQL, indexed causal DAG, identity, diagnostics, anomaly, and bounded diff
- CLI capture/open/compare/export/doctor/record, zero-setup demo, project profiles, and HTTPS relay enrollment
- safe segmented `.beamtrace` v2 with paired graph segments, calibrated clocks, strict checksums, v1 migration, paged API, and interval-aware HTML/JSONL/Mermaid/OTLP exports
- bounded Live process sampling without mailbox contents
- Web workspace, Canvas window, accessible event table and inspector
- TUI attach/arm/search/save interaction model
- OIDC discovery/callback verification, CSRF, RBAC, and team HTTP middleware
- production relay v3 with declared event schema and separate delivery status, relay-v2 migration input, SQLite WAL metadata/segment indexes, filesystem blobs, event-aware quotas, legal hold, startup/hourly retention, and audit-chain contracts
- persistent signed outbound relay WebSocket, one-time Ed25519 enrollment, credit-based batches, and canonical metadata privacy validation
- relay producer capture from attached target nodes, including bounded audited raw grants
- shared live-session fan-out and full multi-trace visual Compare workspace
- HTTPS S3-compatible SigV4 blobs with conditional writes, verified reads, retention, and real MinIO TLS acceptance
- indexed search, causal-neighborhood compare with explicit ambiguity/frontier paths, and interval p50/p95 with valid/missing sample counts
- real Chromium acceptance over one million logical events, keyboard/axe checks, PTY harness, and package smoke tests
- self-contained native archive packaging with bundled ERTS and SQLite NIF, SPDX SBOM/checksums, OCI image, Hex tarball, Homebrew/Scoop metadata, and GitHub release provenance
- official MCP 2026-07-28 lifecycle/tool schemas tested against the exact 2.0.0 client
- responsive one/two/three-panel etui layout and Web/TUI Team trace selectors with locked raw content

## Post-alpha release operations

- publish source-repository-specific Homebrew tap and Scoop bucket metadata when those repositories exist
- configure the repository-scoped release App and short-lived Hex credential before approving the first release PR
- review all five supported native archive candidates on the release PR; merging that PR is the sole publication approval
- add Windows ARM64 packaging once CI can build or provision a reproducible native Erlang/OTP runtime without relabeling an x64 runtime

Runtime features stay listed as implemented only after an acceptance test exercises the real boundary. A type or pure policy module alone does not mark an integration complete.
