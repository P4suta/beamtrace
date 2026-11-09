<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Environment variables

This page is the complete reference for every `BEAMTRACE_*` variable read by
shipped code, in three tiers. `scripts/check-env-docs.mjs` keeps it in sync
with the sources in both directions, so a variable that is missing here — or
listed here but no longer read — fails CI.

## User contract

Variables you may set when running the CLI.

| Variable | Meaning | Default / unset behaviour | Accepted values |
|---|---|---|---|
| `BEAMTRACE_COOKIE` | Supplies the distribution cookie for `attach`/`capture`/`record` targets. | `attach`/`capture` fall back to a secure prompt; `record` generates an ephemeral random cookie. | 1–255 bytes after trimming. `--cookie-file` takes precedence. |
| `BEAMTRACE_COOKIE_FILE` | Adds one cookie file path to the permission audit run by `beamtrace doctor`. It does **not** supply a cookie — use `--cookie-file` or `BEAMTRACE_COOKIE` for that. | Only `beamtrace.toml` `cookie_file` entries are audited. | A file path; the file must be private (no group/other permission bits). |
| `BEAMTRACE_AGENT_BEAM` | Path to the injected agent BEAM used by `record`/`capture`/`demo`. | The loaded `beamtrace_agent` module is used; when neither exists the command stops with `E_AGENT_BEAM_UNAVAILABLE`. | A `.beam` file that names module `beamtrace_agent` and exports its full agent API; anything else is rejected. |
| `BEAMTRACE_WEB_ROOT` | Root directory of the Web workspace assets. | `../beamtrace_web/dist` relative to the runtime. | A directory containing `index.html`, `beamtrace_web.js`, and `styles.css`. |
| `BEAMTRACE_LOG_FORMAT` | Output format of structured logs. | `human` (also for unrecognised values). | Exactly `json` for JSON lines; any other value keeps the human format. |

> Note: while a Team-forbidden variable (`BEAMTRACE_COOKIE`,
> `BEAMTRACE_COOKIE_FILE`, `BEAMTRACE_OIDC_CLIENT_SECRET`) exists in the
> process environment — even empty — `beamtrace serve` refuses to start, in
> Local mode too. Unset them before serving.

## Team server configuration

Read once at `beamtrace serve` startup when Team mode is enabled. TLS is
terminated by your reverse proxy; `BEAMTRACE_ORIGIN` is the public HTTPS
origin. `docs/team-mode.md` describes the workflows.

| Variable | Meaning | Default | Accepted values |
|---|---|---|---|
| `BEAMTRACE_TEAM` | Enables Team mode. | Local mode. | `true`/`1`/`yes` to enable, `false`/`0`/`no` to disable (case-sensitive); anything else fails startup. |
| `BEAMTRACE_ORIGIN` | Public HTTPS origin of the deployment. | **Required.** | `https://host` (no userinfo, query, fragment, or path beyond `/`). |
| `BEAMTRACE_BIND` | Listen address. | `127.0.0.1` | Any bindable address string. |
| `BEAMTRACE_PORT` | Listen port. In Team mode this replaces `serve --port`. | `4040` | Integer 1–65535. |
| `BEAMTRACE_DATA_DIR` | Directory for SQLite and blob data. | `beamtrace-data` | 1–4096 bytes. |
| `BEAMTRACE_PROJECT` | Project identifier. | **Required.** | 1–256 bytes. |
| `BEAMTRACE_ENVIRONMENT` | Environment identifier. | **Required.** | 1–256 bytes. |
| `BEAMTRACE_RETENTION_DAYS` | Metadata retention. | `7` | Integer 1–3650. |
| `BEAMTRACE_RAW_RETENTION_DAYS` | Raw capture retention. | `1` | Integer 1–3650, at most `BEAMTRACE_RETENTION_DAYS`. |
| `BEAMTRACE_RELAY_MAX_EVENTS` | Per-session relay event cap. | `1000000` | Integer up to 1e9. |
| `BEAMTRACE_RELAY_MAX_BYTES` | Per-session relay byte cap. | `1073741824` | Integer up to 1e12. |
| `BEAMTRACE_ENROLLMENT_TTL_MS` | Relay enrollment code lifetime. | `600000` | Integer 1–86400000. |
| `BEAMTRACE_BLOB_BACKEND` | Blob storage backend. | `filesystem` | `filesystem` or `s3`. |
| `BEAMTRACE_S3_ENDPOINT` | S3-compatible endpoint. | Required for `s3`. | HTTPS origin only. |
| `BEAMTRACE_S3_BUCKET` | Bucket name. | Required for `s3`. | 3–63 bytes, `[a-z0-9.-]`, no `..`, alphanumeric ends. |
| `BEAMTRACE_S3_REGION` | SigV4 signing region. | `us-east-1` | 1–64 bytes, alphanumerics and `-`. |
| `BEAMTRACE_S3_PREFIX` | Object key prefix. | `beamtrace` | ≤512 bytes, no NUL/`\`/`:`, no trailing `/`. |
| `BEAMTRACE_OIDC_ISSUER` | OIDC issuer; discovery starts here. | **Required.** | HTTPS URL. |
| `BEAMTRACE_OIDC_CLIENT_ID` | OIDC client id. | **Required.** | 1–512 bytes. |
| `BEAMTRACE_OIDC_AUTHORIZATION_ENDPOINT` | Authorization endpoint. | Discovered from the issuer when all three explicit endpoints are unset; setting any one makes all three required. | HTTPS URL. |
| `BEAMTRACE_OIDC_TOKEN_ENDPOINT` | Token endpoint. | Same discovery rule. | HTTPS URL. |
| `BEAMTRACE_OIDC_JWKS_FILE` | Public JWKS JSON file. | Same discovery rule. | Path to a ≤1 MiB file of public signing keys. |
| `BEAMTRACE_OIDC_REDIRECT_URI` | OIDC callback URI. | **Required.** | Must equal `BEAMTRACE_ORIGIN` + `/auth/oidc/callback` exactly. |
| `BEAMTRACE_OIDC_GROUP_ROLES` | IdP group → role mapping. | **Required.** | Comma-separated `group:role`; roles are `admin`, `investigator`, `viewer`, `raw`; groups non-empty and unique. |
| `BEAMTRACE_OIDC_CLIENT_SECRET` | Never set this. Its mere presence fails startup: BeamTrace's OIDC flow is public-client PKCE and refuses secrets. | — | None. |

S3 credentials use the standard AWS names, read per request and never
stored: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, optional
`AWS_SESSION_TOKEN`, and optional `AWS_CA_BUNDLE` (PEM trust bundle; the OS
trust store is the default). Instance-role provider chains are not
supported.

## Internal, reserved — do not set

These names are wrapper IPC between BeamTrace processes. They carry no
compatibility promise, are overwritten or erased by the CLI, and setting
them can only break a run.

| Reserved | Purpose |
|---|---|
| `BEAMTRACE_RECORD_*` | Parent CLI → record child VM handshake (gates, staged BEAM paths, node name and name domain, wrapper mode). |
| `BEAMTRACE_PARENT_*` | Saved copies of the caller's `PATH`/`ROOTDIR`/`ERL_LIBS`, restored for the child toolchain when running from the bundled runtime. |
| `BEAMTRACE_BUNDLED_RUNTIME` | Set to `1` by the launcher scripts to mark the bundled ERTS; it scopes tool lookup and environment scrubbing. |

Test-only variables (for example `BEAMTRACE_TEST_*`, `BEAMTRACE_PROBE_*`,
`BEAMTRACE_REQUIRE_*`) live outside shipped code and are not part of any
contract.
