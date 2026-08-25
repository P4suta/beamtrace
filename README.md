<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# BeamTrace

[![TDD](https://github.com/P4suta/beamtrace/actions/workflows/ci.yml/badge.svg)](https://github.com/P4suta/beamtrace/actions/workflows/ci.yml)
[![Security](https://github.com/P4suta/beamtrace/actions/workflows/security.yml/badge.svg)](https://github.com/P4suta/beamtrace/actions/workflows/security.yml)

BeamTrace is an open-source causal workbench for Gleam, Elixir, and Erlang systems on the BEAM. It attaches to an existing OTP 27–29 node without application changes, arms a selected MFA, and records the bounded message chain caused by one operation.

The command is `beamtrace`, and its portable trace archive uses the `.beamtrace` extension.

The project is alpha software. Exact single-node and distributed capture, metadata-safe trace storage, offline and multi-run compare, bounded live sampling, indexed search, the Web workspace, and the TUI client are implemented. Team mode includes OIDC discovery and callback verification, RBAC/CSRF enforcement, SQLite WAL metadata, durable annotations and hash-chained audit history, filesystem or S3-compatible blob storage, one-time Ed25519 enrollment, a signed outbound relay WebSocket with credit flow, and separately authorized bounded raw capture.

## Why BeamTrace

- **Capture** — arm `Module:function/arity`, perform one operation, and keep the complete matching root chain rather than an unrelated system-wide message stream.
- **Live** — inspect bounded process samples and diagnose mailbox, reductions, memory, restart, fan-in, and dangling-call signals without reading every mailbox.
- **Compare** — align traces by logical process and causal shape instead of PID or wall-clock identity.
- **Honest evidence** — every edge is `Exact` or `Inferred(reason, confidence)`. Missing nodes, dropped events, ports, ETS, and external I/O remain explicit boundaries.

BeamTrace does not expose an RPC shell, process killing, state mutation, or an ETS browser.

## Quick start

Building from source requires Gleam 1.18.x and Erlang/OTP 27, 28, or 29. Native release archives include ERTS and do not require a host Erlang installation.

```powershell
# Run the complete local TDD gate
./scripts/test-all.ps1

# Capture the bundled fixture through the real record path, without setup
./scripts/beamtrace.ps1 demo --no-ui --out demo.beamtrace

# Create and validate project-local, non-secret capture profiles
./scripts/beamtrace.ps1 init
./scripts/beamtrace.ps1 config check

# Check the local runtime
./scripts/beamtrace.ps1 doctor --json

# Use a profile; explicit CLI values override profile and project defaults.
./scripts/beamtrace.ps1 capture --profile local --node app@host

# Open a bounded Web workspace on an OS-selected loopback port
./scripts/beamtrace.ps1 open checkout.beamtrace --web --port 0
```

On macOS or Linux, invoke the same PowerShell scripts with `pwsh -File`, or run the package commands directly from their directories.

`beamtrace init` creates `beamtrace.toml` only when it does not already exist.
Its `[defaults]` and `[profiles.NAME]` tables may contain `node`, `trigger`,
`where`, `out`, `cookie_file`, `max_roots`, and `preset`. Precedence is explicit
CLI value, selected profile, project defaults, then built-in defaults. Relative
`out` and `cookie_file` paths resolve from the configuration file, not the
invoking directory. Commands, cookie values, grants, tokens, and OIDC/S3 secret
keys are rejected recursively. `beamtrace config check` validates TOML, MFA,
AQL, presets, bounds, and paths without starting capture.

## Repository layout

| Path | Responsibility |
| --- | --- |
| `packages/beamtrace_core` | target-independent types, AQL, DAG, identity, anomaly, diff, codec |
| `packages/beamtrace_runtime` | CLI, hub API, collector, relay protocol, storage, exports |
| `packages/beamtrace_web` | Lustre SPA and bounded Canvas renderer |
| `packages/beamtrace_tui` | canonical terminal client built with `etui` |
| `agent` | dependency-free Erlang module injected temporarily into target nodes |
| `fixtures` | equivalent Gleam, Elixir, and Erlang supervision/call/crash fixtures |

The hub never receives a distribution cookie in team mode. A relay joins the target environment, registers an Ed25519 public key through a one-time HTTPS enrollment code, and initiates outbound connections only. The public key and enrollment audit survive hub restarts; relay private keys, distribution cookies, and nonce replay caches are never persisted by the hub.

The Admin-only `/api/v1/audit` endpoint exposes the verified audit chain with bounded pagination (at most 200 entries per request). Viewer and unauthenticated requests are rejected, and each page includes the current chain head for integrity checks.

See [team mode](docs/team-mode.md) for OIDC, relay, raw-capture, and S3 configuration.

## Operational boundaries

- Metadata capture remains the default. Raw relay capture requires both Investigator and Raw Capture roles, a short-lived one-time grant, explicit redaction keys, and strict duration/event/byte/depth/binary budgets; every authorization outcome is audited.
- Raw and conservatively classified `unknown` content can be read only by an Admin or a subject holding both Investigator and Raw Capture roles. Authorization happens before any memory, filesystem, or S3 blob fetch, and allowed and denied reads are audited.
- The S3-compatible adapter uses HTTPS path-style requests and SigV4 credentials from process environment only. It intentionally does not accept credentials in BeamTrace configuration or implement a general cloud credential-provider chain.
- Causal order crosses nodes through sequence serials. Clock offsets retain uncertainty and are never presented as a perfectly synchronized global clock.
- Package-manager registry publication and the first signed release remain release operations, not runtime implementation gaps.

## CLI

```text
beamtrace attach <node> [--web|--tui] [--port PORT]
beamtrace capture [<node>] [--profile NAME] --trigger Module:function/arity [--where AQL] --out file.beamtrace
beamtrace record [--profile NAME] [--node NODE] [options] -- <gleam|mix|rebar3|erl command>
beamtrace open <file.beamtrace> [--web|--tui] [--port PORT]
beamtrace compare <left.beamtrace> <right.beamtrace>
beamtrace export <file.beamtrace> --format html|jsonl|mermaid|otlp
beamtrace serve [--port PORT]
beamtrace demo [--web|--tui|--no-ui] [--out PATH] [--port PORT]
beamtrace relay <https-hub-url> --enroll <one-time-token> [--node NODE --trigger MFA]
                [--cookie-file PATH] [--raw-grant-file PATH]
beamtrace tui [--server <url>] [--session-cookie-file <0600-file>]
beamtrace init
beamtrace config check
beamtrace doctor [--json]
beamtrace mcp
```

Exit codes are `0` success, `1` comparison/diagnostic policy failure, `2` usage/connect/configuration error, `3` incomplete capture, and `4` permission or safety refusal.

`record` resolves the requested executable once and launches it without a shell, preserving every argument boundary and mise/asdf shim path. Direct Erlang gates its VM immediately. `gleam run`, `mix run`, and `rebar3 shell` first perform a bounded compile only when the trigger BEAM is absent, then gate the final project VM; Gleam recording requires the Erlang target and adds it when omitted. All paths use a private one-time OS temp directory and remove it after success, failure, timeout, or termination.

Team TUI loading uses the same bounded `/api/v1/traces` response as the Web selector. Pass the current OIDC session ID through a regular `0600` file; BeamTrace never accepts it as a command-line value. Cleartext HTTP is accepted only for `localhost`, `127.0.0.1`, or `::1`; remote Team origins require verified HTTPS.

## Safety defaults

- OTP isolated trace sessions avoid changing another tracer's flags.
- Exact capture refuses to replace an occupied system tracer.
- Metadata mode exports term tags, shapes, sizes, and salted fingerprints—not scalar or binary values.
- Raw grants are token-hashed at rest, relay-bound, atomically budgeted, and removed from canonical stored payloads.
- Exact capture truncates on backpressure; Live drops old samples only with an explicit `Gap`.
- Trace archives reject unsafe paths, duplicate entries, suspicious compression ratios, oversized entries, and checksum mismatches before import.
- Local Web mode binds loopback and exchanges a one-time URL for an HttpOnly, SameSite cookie.
- `/api/v1/health` reports liveness and `/api/v1/ready` is installed only after initialization and bind succeed. URLs, bootstrap tokens, and enrollment codes are never printed before a successful bind.
- Human and JSON logs omit distribution cookies, session tokens, raw payloads, OIDC material, and S3 credentials.
- There is no telemetry, CDN, external font, or external request in exported HTML.

Read [the threat model](docs/threat-model.md) before deploying a relay or enabling raw capture.

## Development

Every change follows Red → Green → Refactor. The merge gate is:

```powershell
./scripts/test-all.ps1
```

CI runs OTP 27–29 on Windows, Linux, and macOS, plus shortname, longname, TLS distribution, real S3-compatible TLS, Chromium, PTY, MCP official-client, clean Erlang/JavaScript Hex-consumer, package, and OCI suites. Every native ZIP is compared with the published v0.1.0 target baseline and fails above 5% growth. See [development.md](docs/development.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [repository governance](docs/github-governance.md).

Questions belong in [GitHub Discussions](https://github.com/P4suta/beamtrace/discussions/categories/q-a), confirmed defects use the structured issue forms, and suspected vulnerabilities use a private security advisory. See [SUPPORT.md](SUPPORT.md), [SECURITY.md](SECURITY.md), and [GOVERNANCE.md](GOVERNANCE.md).

Release Please proposes alpha releases from Conventional Commits. Merging its release PR is the publication approval; the resulting protected tag builds five self-contained native OS/architecture archives, publishes `beamtrace_core` to Hex, publishes immutable version and commit tags to GHCR, and attaches Homebrew/Scoop metadata to a GitHub prerelease. Archives contain ERTS, checksums, and SPDX SBOM data; GitHub OIDC artifact attestations record build provenance. Windows ARM64 is deferred until a reproducible native Erlang/OTP runtime can be provisioned; an x64 runtime is never relabeled as ARM64. See [releasing.md](docs/releasing.md).

## License

BeamTrace is dual-licensed under your choice of [Apache-2.0](LICENSES/Apache-2.0.txt) or [MIT](LICENSES/MIT.txt). The repository follows REUSE metadata conventions.
