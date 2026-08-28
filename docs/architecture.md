<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Architecture

BeamTrace separates code by trust boundary rather than only by UI.

```text
target BEAM node
  └─ dependency-free beamtrace_agent
       └─ credit-bounded batches
            └─ relay (owns distribution cookie)
                 └─ outbound TLS only
                      └─ hub/API/storage (never owns cookie)
                           ├─ Lustre Web workspace
                           └─ etui terminal client
```

In local mode the relay and hub share one runtime process and the API binds loopback. In team mode only the relay lives beside the target environment.

## Capture

The relay injects a fixed-name, version-hashed Erlang BEAM with `code:load_binary`. The agent creates an isolated OTP trace session, installs a meta trace on one MFA, and adds a sequential trace token only to a process that hits that root. It does not enable ordinary call tracing for every process.

The seq_trace system tracer is exclusive. If one already exists, exact capture is refused rather than overwriting it. Attach-mode capture requires explicit acknowledgement that cleanup resets the VM-global seq_trace state; `record` runs an isolated VM. Cleanup removes BeamTrace trace flags, resets its sequential label, stops the agent, and unloads its module.

Distributed capture installs passive agents with the same bounded sequential label. Quiet time starts seal: each agent disables new tracing, passes `trace:delivered/2` and the seq_trace delivery barrier, drains its credit queue, and returns a final sequence/event/byte receipt. Node-local relative monotonic time is retained; full `{previous,current}` sequence serials define exact partial order. Seven before/after minimum-RTT probes retain interpolated uncertainty and never create causal edges.

## Data plane

Exact mode seals with a `budget_reached` observation end when a queue or byte/event budget is exhausted. Batch gaps, duplicates, receipt mismatches, missing nodes, drops, and drain timeouts are independent integrity issues. Live mode may discard oldest samples but emits a `Gap` count. The shared credit policy starts at eight batches and replenishes to eight only after durable acceptance crosses four remaining credits. Relay batches obey both the 128-event limit and the signed WebSocket byte limit: an oversized multi-event prefix is split before consuming credit, while one intrinsically oversized event is refused and transfer delivery fails explicitly.

Term shaping happens on the observed node. Metadata mode preserves constructors, tags, collection sizes, and salted fingerprints. Values never cross the relay boundary.

At the team ingress, every signed batch is decoded as canonical `TraceEvent` values before storage. Unknown top-level fields, forbidden scalar displays, malformed fingerprints, and batches over 128 events are rejected. Metadata is always the default. Raw batches additionally require a relay-bound one-time grant whose token is stored only as a hash; the hub atomically reserves its event/byte budget, validates the exact redaction/depth/binary policy, removes the token from canonical persistence, and audits authorization. The hub accounts quota using session event counts, not WebSocket frame count. Credit is replenished only after durable acceptance; quota, privacy, protocol, and inbox failures stop or truncate the producer instead of acknowledging unpersisted data.

Relay protocol v3 signs `session_start`, `batch`, and `session_end`, declares event schema v2, and keeps transfer `delivery_status` separate from the embedded causal outcome. A 128-bit session ID fixes relay ownership, node/MFA, mode, privacy, and start time. Sequence, event/byte quota, credit, delivery status, and retention are session-scoped. One relay can own one active session and the hub accepts at most 64 active sessions. Reconnect is accepted only for identical immutable metadata and exact batch replays are idempotent before quota, raw-grant, blob, and inbox accounting. The client reports success only after the hub commits `session_end` and returns the matching v3 `session_ack`. Protocol v2 is accepted only as migration input; protocol v1 receives an upgrade-required refusal.

## Team control plane

OIDC discovery and authorization-code callbacks enforce exact issuer/redirect checks, state, nonce, PKCE, ID-token signature/time claims, CSRF, and role permissions. There are no embedded password accounts. Relay enrollment codes are one-time values consumed atomically when an Ed25519 public key is registered.

SQLite WAL schema version 9 connects `sessions`, `relay_session_details`, `event_segments`, and relay frames to the production data path, alongside relay identities, annotations, raw-grant budgets, retention deletion outbox entries, and the append-only audit chain. Legacy relay frames migrate into synthetic `unknown` and `incomplete` sessions rather than being discarded. Annotation IDs come from a monotonic SQLite sequence and survive restarts. Audit writes are serialized, persisted before acknowledgement, and retain the previous hash and entry hash. Audit chains are verified when the team runtime opens; a shape-valid but reordered or modified chain prevents startup. The Admin-only `GET /api/v1/audit` route returns bounded pages of at most 200 verified entries and rejects Viewer or anonymous access. Registered relay public keys are restored after a hub restart, so a relay reconnects without enrollment reuse; private keys and nonce replay caches remain outside hub storage. New enrollment is committed before its one-time code becomes used, and a storage failure leaves the code retryable.

The Team trace library exposes opaque-cursor `GET /api/v1/traces` pages (50 by default, 100 maximum), detail, and event pages of at most 200 events. The former relay-frame endpoint returns `410 Gone`. Raw and `unknown` content stays locked unless the subject is Admin or holds both Investigator and Raw Capture roles; the full content request becomes `403` before memory, filesystem, or S3 retrieval, and allowed/denied reads enter the audit chain. Admin-only legal-hold POST/DELETE operations require CSRF and are audited. Retention runs at startup and hourly from hub receive time, defaults to seven days for metadata and one day for raw, enforces raw retention no longer than metadata retention, and skips held traces.

## Storage and clients

An `.beamtrace` v2 ZIP contains a structured manifest, canonical event segments, paired graph segments, clock calibration, index, annotations, and an exact SHA-256 inventory. Schema v1 is read-only migration input. The local Web API reads at most 1,000 events per request and the Team trace API at most 200; both decompress only needed segments. Canvas receives API-declared edges and boundaries for the visible observation; it never connects adjacent rows. Accessible tables and inspectors remain DOM elements.

Core types compile for Erlang and JavaScript. Runtime code targets Erlang. The Web client targets JavaScript. OS, crypto, ZIP, trace, and Canvas operations use narrow FFI modules.

Server-side search verifies and scans one compressed event segment at a time and returns a bounded window; indexed range reads inflate at most two event segments. The browser represents million-event traces by logical totals and window cursors, never by loading every event or creating one DOM node per event. Multi-run statistics use root-relative durations and logical causal signatures, so physical PIDs and node-local clock origins do not affect alignment.

The S3 adapter uses path-style HTTPS requests, AWS Signature Version 4, conditional create-only PUT, content hash verification, bounded responses, disabled redirects, peer/hostname verification, and optional `AWS_CA_BUNDLE`. Credentials are read only from standard AWS process environment variables and never enter BeamTrace configuration, SQLite, logs, or frames.

Portable ZIP releases include the platform SQLite NIF, Web assets, the injected agent, a minimal OTP 27–29 runtime closure, ERTS, SHA-256 inventories, and an SPDX 2.3 SBOM. Compiler/analysis-only ERTS commands and OTP's crypto test engine are excluded only after the packaged execution closure passes; the production crypto NIF and SSL modules remain. Package acceptance empties `PATH` before running `version`, `doctor`, real `record`, and a team-server smoke test, proving that host Erlang is not used. All five native candidates run that closure and fail if their ZIP grows more than 5% above its published v0.1.0 target baseline. The OCI image supplies OTP 29, uses a non-root account, and is smoke-tested through the packaged commands.
