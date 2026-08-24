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

Exact mode stops and reports `Truncated` when a queue or byte/event budget is exhausted. Live mode may discard oldest samples but emits a `Gap` count. Credits bound both agent and relay queues. Relay batches obey both the 128-event limit and the signed WebSocket byte limit: an oversized multi-event prefix is split before consuming credit, while one intrinsically oversized event is refused and the transfer exits incomplete.

Term shaping happens on the observed node. Metadata mode preserves constructors, tags, collection sizes, and salted fingerprints. Values never cross the relay boundary.

At the team ingress, every signed batch is decoded as canonical `TraceEvent` values before storage. Unknown top-level fields, forbidden scalar displays, malformed fingerprints, and batches over 128 events are rejected. Metadata is always the default. Raw batches additionally require a relay-bound one-time grant whose token is stored only as a hash; the hub atomically reserves its event/byte budget, validates the exact redaction/depth/binary policy, removes the token from canonical persistence, and audits authorization. The hub accounts quota using `relay_frames.event_count`, not WebSocket frame count. Credit is replenished only after durable acceptance; quota, privacy, protocol, and inbox failures stop or truncate the producer instead of acknowledging unpersisted data.

## Team control plane

OIDC discovery and authorization-code callbacks enforce exact issuer/redirect checks, state, nonce, PKCE, ID-token signature/time claims, CSRF, and role permissions. There are no embedded password accounts. Relay enrollment codes are one-time values consumed atomically when an Ed25519 public key is registered.

SQLite WAL schema version 7 stores team sessions, relay identities, frame indexes, event counts, conservative `metadata`/`raw`/`unknown` frame privacy classifications, annotations, raw-grant hashes and budgets, and append-only audit entries. Existing relay frames migrate to `unknown` so raw-read authorization remains fail-closed. Annotation IDs come from a monotonic SQLite sequence and survive restarts. Audit writes are serialized, persisted before acknowledgement, and retain the previous hash and entry hash. Audit chains are verified when the team runtime opens; a shape-valid but reordered or modified chain prevents startup. The Admin-only `GET /api/v1/audit` route returns bounded pages of at most 200 verified entries and rejects Viewer or anonymous access. Registered relay public keys are restored after a hub restart, so a relay reconnects without enrollment reuse; private keys and nonce replay caches remain outside hub storage. New enrollment is committed before its one-time code becomes used, and a storage failure leaves the code retryable. Startup retention pruning applies project/environment policy to either validated filesystem keys or HTTPS S3-compatible objects.

## Storage and clients

An `.beamtrace` is a versioned ZIP container with manifest, segmented NDJSON, metadata, indexes, annotations, and SHA-256 checksums. The Web API reads at most 1,000 events per request and decompresses only the needed segments. Canvas receives only the current visible metadata rows; accessible tables and inspectors remain DOM elements.

Core types compile for Erlang and JavaScript. Runtime code targets Erlang. The Web client targets JavaScript. OS, crypto, ZIP, trace, and Canvas operations use narrow FFI modules.

Server-side search scans only relevant compressed segments and returns a bounded window. The browser represents million-event traces by logical totals and window cursors, never by loading every event or creating one DOM node per event. Multi-run statistics use root-relative durations and logical causal signatures, so physical PIDs and node-local clock origins do not affect alignment.

The S3 adapter uses path-style HTTPS requests, AWS Signature Version 4, conditional create-only PUT, content hash verification, bounded responses, disabled redirects, peer/hostname verification, and optional `AWS_CA_BUNDLE`. Credentials are read only from standard AWS process environment variables and never enter BeamTrace configuration, SQLite, logs, or frames.

Portable ZIP releases include the platform SQLite NIF, Web assets, the injected agent, a minimal OTP 27–29 runtime closure, ERTS, SHA-256 inventories, and an SPDX 2.3 SBOM. Package acceptance empties `PATH` before running `version`, `doctor`, and a team-server smoke test, proving that host Erlang is not used. The OCI image supplies OTP 29, uses a non-root account, and is smoke-tested through the packaged commands.
