<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Team mode

Team mode keeps BEAM distribution authority at the relay. The hub stores relay public keys and trace data, but never receives a distribution cookie, relay private key, or arbitrary RPC capability. Terminate public TLS at a trusted reverse proxy and set `BEAMTRACE_ORIGIN` to the exact external HTTPS origin.

## Hub configuration

Set `BEAMTRACE_TEAM=1`, then provide:

- `BEAMTRACE_ORIGIN`, `BEAMTRACE_BIND`, `BEAMTRACE_PORT`, and `BEAMTRACE_DATA_DIR`
- `BEAMTRACE_OIDC_AUTHORIZATION_ENDPOINT`, `BEAMTRACE_OIDC_TOKEN_ENDPOINT`, `BEAMTRACE_OIDC_ISSUER`, `BEAMTRACE_OIDC_CLIENT_ID`, `BEAMTRACE_OIDC_REDIRECT_URI`, and `BEAMTRACE_OIDC_JWKS_FILE`
- `BEAMTRACE_OIDC_GROUP_ROLES`, for example `beam-viewers:viewer,beam-investigators:investigator,beam-raw:raw,beam-admins:admin`
- `BEAMTRACE_PROJECT` and `BEAMTRACE_ENVIRONMENT`

Optional bounded settings are `BEAMTRACE_RETENTION_DAYS` (default 7), `BEAMTRACE_RAW_RETENTION_DAYS` (default 1 and never greater than metadata retention), `BEAMTRACE_RELAY_MAX_EVENTS`, `BEAMTRACE_RELAY_MAX_BYTES`, and `BEAMTRACE_ENROLLMENT_TTL_MS`. Client secrets, distribution cookies, and S3 credentials are rejected if supplied through BeamTrace configuration.

At startup the hub prints a one-time relay enrollment code. Deliver it through an authenticated operational channel; it is consumed atomically when the relay's Ed25519 public key is committed.

## S3-compatible blobs

Filesystem blobs are the default. To use S3-compatible storage, set:

```text
BEAMTRACE_BLOB_BACKEND=s3
BEAMTRACE_S3_ENDPOINT=https://objects.example
BEAMTRACE_S3_BUCKET=beamtrace-prod
BEAMTRACE_S3_REGION=ap-northeast-1
BEAMTRACE_S3_PREFIX=beamtrace/team-a
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_SESSION_TOKEN=...              # optional
AWS_CA_BUNDLE=/run/secrets/ca.pem  # optional, at most 1 MiB
```

The endpoint must be an HTTPS origin without credentials, query, fragment, or path. BeamTrace uses path-style SigV4 requests, create-only conditional PUTs, verified bounded GETs, and idempotent DELETEs. Configure bucket IAM, encryption, lifecycle, and backup policy outside BeamTrace. Credentials are read per request from the standard AWS environment variables and are never copied into SQLite or trace frames.

## Metadata relay capture

The relay can remain connected without a target, or capture directly from one:

```text
beamtrace relay https://hub.example --enroll ENROLLMENT_CODE \
  --node app@host --trigger shop:checkout/1 \
  --where 'message.tag == call' --cookie-file /run/secrets/beam.cookie
```

The relay injects the bounded agent, captures one armed operation, opens a signed v2 session, and sends batches only when it has hub credit. It reports success only after the hub durably commits `session_end` and returns the matching `session_ack`. Exact capture truncates instead of sampling when any budget is exhausted. One relay owns at most one active session; the hub-wide default is 64. Disconnect without an end marks the session `incomplete`, and a reconnect may resume only with identical immutable metadata and idempotent sequence replays.

## Raw relay capture

Raw capture is an exceptional workflow, not a server default. The authenticated subject must have both `investigator` and `raw` roles (an Admin also qualifies), and every allowed or denied authorization is appended to the audit chain.

1. Start the relay with `--raw-grant-file` pointing to a not-yet-created, access-restricted file. After enrollment it prints its relay ID and waits for up to five minutes.
2. POST JSON to `/api/v1/raw-captures/authorize` from the authenticated team session with the exact Origin, `x-beamtrace-csrf` header, and matching CSRF cookie.
3. Write the complete `201` JSON response to the requested grant file without modifying it. The relay verifies its ID, expiry, normalized policy, token shape, and all limits before arming.
4. Delete the receipt file securely after the relay consumes it. The hub stores only the token hash; canonical relay payloads and blobs never contain the bearer token.

Example request body:

```json
{
  "relay_id": "relay-00112233445566778899aabb",
  "duration_ms": 10000,
  "max_events": 10000,
  "max_bytes": 4000000,
  "redact_keys": ["authorization", "cookie", "password", "token"],
  "max_depth": 8,
  "max_binary_bytes": 4096
}
```

Hard ceilings are 30 seconds, 100,000 events, 64 MB, depth 32, binary metadata 1 MiB, 128 redaction keys, and 128 events per relay batch. The grant is bound to one enrolled relay and its exact canonical policy. Event and byte consumption is reserved atomically. An exact retry of an already durable session sequence is accepted without consuming the grant twice; a conflicting replay, expiry, relay mismatch, policy drift, or exhaustion is denied generically.

## Team trace library

The Web and TUI trace selectors use these bounded routes:

- `GET /api/v1/traces` uses an opaque cursor, defaults to 50 rows, and accepts at most 100.
- `GET /api/v1/traces/:id` returns status, node/MFA, privacy, completeness, event count, receive time, and hold state.
- `GET /api/v1/traces/:id/events` returns at most 200 events.
- `POST` and `DELETE /api/v1/traces/:id/hold` require Admin, an exact Origin, CSRF cookie/header agreement, and an audit write.

The former `/api/v1/relays/:id/frames` representation is gone and returns
`410 Gone`. Viewer, Investigator-only, and Raw-only sessions see raw or legacy
`unknown` content as locked. Only Admin or the combined Investigator and Raw
Capture roles can retrieve it. The server makes that decision before reading
an in-memory value or fetching a filesystem/S3 blob, returns a whole-request
`403` on denial, and audits allowed and denied reads.

The browser uses its HttpOnly OIDC session cookie. For the native TUI, place the current session ID in a regular, non-empty `0600` file and run `beamtrace tui --server https://trace.example --session-cookie-file /secure/path/session`. The cookie value is never accepted directly on the command line. Non-TLS Team URLs are rejected except for loopback development origins.

## Shutdown and retention

SIGINT and SIGTERM stop capture, listeners, SQLite, and the selected blob backend. Disconnect, heartbeat timeout, capture timeout, or budget exhaustion compare-and-restores only BeamTrace-owned tracer state; a relay disconnect also persists the trace as `incomplete` rather than deleting evidence.

Retention runs at startup and hourly using the hub's receive timestamp, not a relay-provided clock. Metadata defaults to seven days and raw to one day; raw retention cannot exceed metadata retention. Legal hold prevents BeamTrace from deleting data until an Admin removes it, and every hold change is audited. Pruning deletes validated filesystem or S3 blob keys and their indexes without touching held sessions. Do not apply an independent expiration rule to the configured S3 prefix: an external lifecycle rule cannot see SQLite legal holds and can permanently remove held evidence. If an operator deliberately permits external deletion, BeamTrace can preserve the held metadata and audit record but cannot promise that the corresponding events remain readable.
