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

The system tracer is exclusive. If one already exists, exact capture returns an explicit inferred/limited result rather than overwriting it. Cleanup removes the meta trace, restores only state owned by BeamTrace, clears the sequential tracer, stops the agent, and unloads its module.

Distributed capture installs passive agents with the same bounded sequential label. Node-local monotonic time is retained; sequence serials define exact partial order. Clock offsets are metadata with uncertainty, never a fabricated global clock.

## Data plane

Exact mode stops and reports `Truncated` when a queue or byte/event budget is exhausted. Live mode may discard oldest samples but emits a `Gap` count. Credits bound both agent and relay queues.

Term shaping happens on the observed node. Metadata mode preserves constructors, tags, collection sizes, and salted fingerprints. Values never cross the relay boundary.

At the team ingress, every signed batch is decoded as canonical `TraceEvent` values before storage. Unknown top-level fields, scalar displays, binary displays, malformed fingerprints, batches over 128 events, and raw mode are rejected. Raw batches are rejected at the team relay boundary until the separate raw permission and audit path exists. The hub accounts quota using `relay_frames.event_count`, not WebSocket frame count. Credit is replenished only after durable acceptance; quota, privacy, and inbox failures stop or truncate the producer instead of acknowledging unpersisted data.

## Team control plane

OIDC discovery and authorization-code callbacks enforce exact issuer/redirect checks, state, nonce, PKCE, ID-token signature/time claims, CSRF, and role permissions. There are no embedded password accounts. Relay enrollment codes are one-time values consumed atomically when an Ed25519 public key is registered.

SQLite WAL schema version 5 stores team sessions, relay identities, frame indexes, event counts, annotations, and append-only audit entries. Annotation IDs come from a monotonic SQLite sequence and survive restarts. Audit writes are serialized, persisted before acknowledgement, and retain the previous hash and entry hash. Audit chains are verified when the team runtime opens; a shape-valid but reordered or modified chain prevents startup. The Admin-only `GET /api/v1/audit` route returns bounded pages of at most 200 verified entries and rejects Viewer or anonymous access. Registered relay public keys are restored after a hub restart, so a relay reconnects without enrollment reuse; private keys and nonce replay caches remain outside hub storage. New enrollment is committed before its one-time code becomes used, and a storage failure leaves the code retryable. Startup retention pruning applies project/environment policy and filesystem blobs are written through validated capture identifiers. The S3-compatible blob adapter remains outside the current alpha boundary.

## Storage and clients

An `.beamtrace` is a versioned ZIP container with manifest, segmented NDJSON, metadata, indexes, annotations, and SHA-256 checksums. The Web API reads at most 1,000 events per request and decompresses only the needed segments. Canvas receives only the current visible metadata rows; accessible tables and inspectors remain DOM elements.

Core types compile for Erlang and JavaScript. Runtime code targets Erlang. The Web client targets JavaScript. OS, crypto, ZIP, trace, and Canvas operations use narrow FFI modules.

Server-side search scans only relevant compressed segments and returns a bounded window. The browser represents million-event traces by logical totals and window cursors, never by loading every event or creating one DOM node per event. Multi-run statistics use root-relative durations and logical causal signatures, so physical PIDs and node-local clock origins do not affect alignment.

Portable ZIP releases include the platform SQLite NIF, Web assets, the injected agent, SHA-256 inventories, and an SPDX 2.3 SBOM. They still use the host OTP runtime. The OCI image supplies OTP 29, uses a non-root account, and is smoke-tested through the packaged `version` and `doctor` commands.
