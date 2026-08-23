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
- indexed search over unloaded segments and PID/clock-independent multi-run p50/p95/occurrence statistics
- real Chromium acceptance over one million logical events, keyboard/axe checks, PTY harness, and package smoke tests
- native archive packaging with SQLite NIF, SPDX SBOM/checksums, OCI image, Hex tarball, Homebrew/Scoop metadata, and GitHub release provenance

## Remaining integration work

- relay CLI producer hookup from an attached target into the validated event-batch API
- S3-compatible blob adapter
- permissioned and audited raw team capture; the current relay boundary rejects raw batches
- shared live-session fan-out and a full multi-trace visual Compare workspace
- bundled ERTS archives that do not require host Erlang/OTP
- source-repository-specific Homebrew tap/Scoop bucket publication and optional Hex registry publication
- native acceptance runs on all six release architectures; the workflow is defined, but hosted CI results are required before the first release

Features stay listed here until an acceptance test exercises the real boundary. A type or pure policy module alone does not mark an integration complete.
