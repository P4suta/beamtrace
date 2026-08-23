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

# Check the local runtime
./scripts/beamtrace.ps1 doctor

# Capture one MFA. The cookie value is never accepted as a CLI argument.
./scripts/beamtrace.ps1 capture app@host `
  --trigger shop:checkout/1 `
  --where 'message.tag == call' `
  --cookie-file .secrets/app.cookie `
  --out checkout.beamtrace

# Open a bounded, paged Web workspace
./scripts/beamtrace.ps1 open checkout.beamtrace --web
```

On macOS or Linux, invoke the same PowerShell scripts with `pwsh -File`, or run the package commands directly from their directories.

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
- The S3-compatible adapter uses HTTPS path-style requests and SigV4 credentials from process environment only. It intentionally does not accept credentials in BeamTrace configuration or implement a general cloud credential-provider chain.
- Causal order crosses nodes through sequence serials. Clock offsets retain uncertainty and are never presented as a perfectly synchronized global clock.
- Package-manager registry publication and the first signed release remain release operations, not runtime implementation gaps.

## CLI

```text
beamtrace attach <node> [--web|--tui]
beamtrace capture <node> --trigger Module:function/arity [--where AQL] --out file.beamtrace
beamtrace record [options] -- <gleam|mix|rebar3 command>
beamtrace open <file.beamtrace> [--web|--tui]
beamtrace compare <left.beamtrace> <right.beamtrace>
beamtrace export <file.beamtrace> --format html|jsonl|mermaid|otlp
beamtrace serve
beamtrace relay <https-hub-url> --enroll <one-time-token> [--node NODE --trigger MFA]
                [--cookie-file PATH] [--raw-grant-file PATH]
beamtrace tui [--server <url>]
beamtrace doctor
beamtrace mcp
```

Exit codes are `0` success, `1` comparison/diagnostic policy failure, `2` usage/connect/configuration error, `3` incomplete capture, and `4` permission or safety refusal.

## Safety defaults

- OTP isolated trace sessions avoid changing another tracer's flags.
- Exact capture refuses to replace an occupied system tracer.
- Metadata mode exports term tags, shapes, sizes, and salted fingerprints—not scalar or binary values.
- Raw grants are token-hashed at rest, relay-bound, atomically budgeted, and removed from canonical stored payloads.
- Exact capture truncates on backpressure; Live drops old samples only with an explicit `Gap`.
- Trace archives reject unsafe paths, duplicate entries, suspicious compression ratios, oversized entries, and checksum mismatches before import.
- Local Web mode binds loopback and exchanges a one-time URL for an HttpOnly, SameSite cookie.
- There is no telemetry, CDN, external font, or external request in exported HTML.

Read [the threat model](docs/threat-model.md) before deploying a relay or enabling raw capture.

## Development

Every change follows Red → Green → Refactor. The merge gate is:

```powershell
./scripts/test-all.ps1
```

CI runs OTP 27–29 on Windows, Linux, and macOS, plus shortname, longname, TLS distribution, real S3-compatible TLS, Chromium, PTY, package, and OCI suites. See [development.md](docs/development.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [repository governance](docs/github-governance.md).

Questions belong in [GitHub Discussions](https://github.com/P4suta/beamtrace/discussions/categories/q-a), confirmed defects use the structured issue forms, and suspected vulnerabilities use a private security advisory. See [SUPPORT.md](SUPPORT.md), [SECURITY.md](SECURITY.md), and [GOVERNANCE.md](GOVERNANCE.md).

Release Please proposes alpha releases from Conventional Commits. Merging its release PR is the publication approval; the resulting protected tag builds five self-contained native OS/architecture archives, publishes `beamtrace_core` to Hex, publishes immutable version and commit tags to GHCR, and attaches Homebrew/Scoop metadata to a GitHub prerelease. Archives contain ERTS, checksums, and SPDX SBOM data; GitHub OIDC artifact attestations record build provenance. Windows ARM64 is deferred until a reproducible native Erlang/OTP runtime can be provisioned; an x64 runtime is never relabeled as ARM64. See [releasing.md](docs/releasing.md).

## License

BeamTrace is dual-licensed under your choice of [Apache-2.0](LICENSES/Apache-2.0.txt) or [MIT](LICENSES/MIT.txt). The repository follows REUSE metadata conventions.
