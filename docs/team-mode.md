<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Team mode

Team mode keeps BEAM distribution authority at the relay. The hub stores relay public keys and trace data, but never receives a distribution cookie, relay private key, or arbitrary RPC capability. Terminate public TLS at a trusted reverse proxy and set `BEAMTRACE_ORIGIN` to the exact external HTTPS origin.

## Hub configuration

Set `BEAMTRACE_TEAM=1`, then provide:

- `BEAMTRACE_ORIGIN`, `BEAMTRACE_BIND`, `BEAMTRACE_PORT`, and `BEAMTRACE_DATA_DIR`
- `BEAMTRACE_OIDC_AUTHORIZATION_ENDPOINT`, `BEAMTRACE_OIDC_TOKEN_ENDPOINT`, `BEAMTRACE_OIDC_ISSUER`, `BEAMTRACE_OIDC_CLIENT_ID`, `BEAMTRACE_OIDC_REDIRECT_URI`, and `BEAMTRACE_OIDC_JWKS_FILE`
- `BEAMTRACE_OIDC_GROUP_ROLES`, for example `beam-viewers:viewer,beam-investigators:investigator,beam-raw:raw,beam-admins:admin`
- `BEAMTRACE_PROJECT` and `BEAMTRACE_ENVIRONMENT`

Optional bounded settings are `BEAMTRACE_RETENTION_DAYS`, `BEAMTRACE_RELAY_MAX_EVENTS`, `BEAMTRACE_RELAY_MAX_BYTES`, and `BEAMTRACE_ENROLLMENT_TTL_MS`. Client secrets, distribution cookies, and S3 credentials are rejected if supplied through BeamTrace configuration.

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

The relay injects the bounded agent, captures one armed operation, sends batches only when it has hub credit, and reports success only after durable acknowledgement. Exact capture truncates instead of sampling when any budget is exhausted.

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

Hard ceilings are 30 seconds, 100,000 events, 64 MB, depth 32, binary metadata 1 MiB, 128 redaction keys, and 128 events per relay batch. The grant is bound to one enrolled relay and its exact canonical policy. Event and byte consumption is reserved atomically, so replay, expiry, relay mismatch, policy drift, or exhaustion is denied generically.

## Shutdown and retention

Disconnect, heartbeat timeout, capture timeout, or budget exhaustion destroys the owned trace session and compare-and-restores only BeamTrace-owned tracer state. Startup retention prunes expired relay frames and their filesystem or S3 blobs. Audit records and metadata follow the configured project/environment retention policy; external S3 lifecycle rules should be no shorter than the BeamTrace policy unless deliberate gaps are acceptable.
