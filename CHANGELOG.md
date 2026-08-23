<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Changelog

All notable changes will be documented here. The format follows Keep a Changelog principles; the project uses semantic versioning after the `0.x` experimental period.

## Unreleased

### Changed

- Standardized the product, CLI, package/module prefixes, environment variables, agent identity, distribution artifacts, and repository directory on `BeamTrace` / `beamtrace` / `BEAMTRACE`.
- Standardized portable trace files on the `.beamtrace` extension. The experimental pre-release naming is intentionally not retained as a compatibility alias.

### Added

- Initial causal capture agent and relay injection lifecycle.
- Versioned `.beamtrace` storage, paged event reads, and safe offline exports.
- Capture, Live, Compare core analysis contracts.
- Lustre Web workspace and `etui` terminal client.
- Team-mode RBAC, OIDC correlation contracts, audit chain, retention policy, quotas, and atomic relay enrollment.
- OTP 27–29 and cross-platform TDD matrix.
- OIDC discovery and token verification, CSRF-aware team middleware, SQLite WAL metadata/index storage, and filesystem blobs.
- Durable SQLite annotations and serialized hash-chained audit entries with restart restoration and tamper rejection.
- Durable Ed25519 relay public-key enrollment with restart authentication, failure-safe one-time codes, and audited enrollment/reuse outcomes.
- Admin-only, bounded audit-chain retrieval through `GET /api/v1/audit`.
- Signed outbound relay WebSocket with Ed25519 enrollment, credit flow, canonical metadata privacy validation, event-count quotas, and durable acknowledgements.
- Indexed bounded search and PID-independent multi-run statistics with p50, p95, and occurrence rates.
- Chromium million-event virtualization, keyboard/accessibility/performance acceptance, and Linux PTY coverage.
- Portable archives with the platform SQLite NIF, SHA-256 inventories, and SPDX 2.3 SBOM; non-root OTP 29 OCI packaging.
- Six-architecture release workflow, Hex tarball, Homebrew/Scoop metadata, and GitHub OIDC artifact attestations.
