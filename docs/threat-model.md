<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Threat model

## Protected assets

- BEAM distribution cookies and TLS private keys
- scalar/binary application values and authentication material
- raw captures and annotations
- target-node availability and scheduler latency
- causal evidence integrity
- team identities, roles, enrollment codes, and audit history

## Trust boundaries

The target node trusts a small injected Erlang module for bounded trace configuration. The relay may hold a distribution cookie. The hub, browser, and TUI must not receive that cookie. Imported traces, browsers, relays before enrollment, and all network input are untrusted.

## Defenses

- isolated trace sessions and compare-before-restore cleanup
- exclusive system tracer acquisition without replacement
- event, byte, duration, mailbox, depth, and binary limits
- metadata-first shaping before data leaves the node
- one-time loopback bootstrap and HttpOnly SameSite cookies
- OIDC state, nonce, PKCE, redirect, CSRF, and RBAC contracts
- Ed25519 relay identity and atomically consumed HTTPS enrollment codes
- durable relay public keys without hub-side private keys, cookies, or nonce material
- canonical relay payload decoding, metadata-first validation, and event-count quotas
- relay-bound raw grants stored as hashes, atomic event/byte reservation, mandatory redaction policy, short expiry, and authorization audit
- credit replenishment only after durable frame acceptance
- TLS peer and hostname verification with redirects disabled
- S3 SigV4 create-only writes, verified reads, bounded bodies, and environment-only credentials
- append-only hash-chained audit records
- archive path, duplicate, size, ratio, checksum, and codec validation
- CSP and offline HTML export with no external resources

## Residual risks and non-goals

A distribution cookie grants broad BEAM capabilities to the relay process; host hardening remains required. Raw capture can expose secrets despite redaction policy. Scheduler and tracing overhead cannot be zero. Ports, ETS state, native code, and external services create causal boundaries. A compromised target VM or relay host is outside the integrity boundary. BeamTrace is not a sandbox, APM, debugger, or incident-response containment tool.

Raw capture remains intrinsically sensitive: role checks, grants, redaction, and bounds reduce exposure but cannot prove that application secrets are absent. Grant receipt files are bearer credentials until consumed and must be created with restrictive permissions and deleted by the operator. Filesystem blobs inherit host confidentiality and backup controls; S3-compatible blobs inherit bucket IAM, retention, server-side encryption, and provider availability controls. Static AWS environment credentials are supported, but a general instance-role/provider chain is not.
