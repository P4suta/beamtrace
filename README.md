<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# BeamTrace

[![TDD](https://github.com/P4suta/beamtrace/actions/workflows/ci.yml/badge.svg)](https://github.com/P4suta/beamtrace/actions/workflows/ci.yml)
[![Security](https://github.com/P4suta/beamtrace/actions/workflows/security.yml/badge.svg)](https://github.com/P4suta/beamtrace/actions/workflows/security.yml)

BeamTrace is an open-source causal workbench for Gleam, Elixir, and Erlang systems on the BEAM. It attaches to an existing OTP 27–29 node without application changes, arms a selected MFA, and records the bounded message chain caused by one operation.

The command is `beamtrace`, and its portable trace archive uses the `.beamtrace` extension.

The project is alpha software. Exact single-node and distributed capture, metadata-safe trace storage, offline and multi-run compare, bounded live sampling, indexed search, the Web workspace, and the TUI client are implemented. Team mode includes OIDC discovery and callback verification, RBAC/CSRF enforcement, SQLite WAL metadata, durable annotations and hash-chained audit history, filesystem blob storage, one-time Ed25519 enrollment, and a signed outbound relay WebSocket with credit flow and durable-ingest acknowledgement.

## Why BeamTrace

- **Capture** — arm `Module:function/arity`, perform one operation, and keep the complete matching root chain rather than an unrelated system-wide message stream.
- **Live** — inspect bounded process samples and diagnose mailbox, reductions, memory, restart, fan-in, and dangling-call signals without reading every mailbox.
- **Compare** — align traces by logical process and causal shape instead of PID or wall-clock identity.
- **Honest evidence** — every edge is `Exact` or `Inferred(reason, confidence)`. Missing nodes, dropped events, ports, ETS, and external I/O remain explicit boundaries.

BeamTrace does not expose an RPC shell, process killing, state mutation, or an ETS browser.

## Quick start

Prerequisites: Gleam 1.18.x and Erlang/OTP 27, 28, or 29.

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

## Current alpha boundaries

- The standalone relay can enroll, authenticate, reconnect, heartbeat, and transfer validated producer batches. The relay CLI producer hookup to a target capture session is not yet wired, so target capture still starts through local `attach`/`capture` commands.
- Raw team relay capture is intentionally rejected until its additional permission, audit, and bounded-redaction path is complete. Metadata batches are decoded, privacy-validated, and canonically re-encoded before persistence.
- Team blobs use the filesystem backend. An S3-compatible backend remains future work.
- Portable archives currently require Erlang/OTP 27–29 on the host. The OCI image contains Erlang and runs as a non-root user; bundled ERTS archives are still pending.

## CLI

```text
beamtrace attach <node> [--web|--tui]
beamtrace capture <node> --trigger Module:function/arity [--where AQL] --out file.beamtrace
beamtrace record [options] -- <gleam|mix|rebar3 command>
beamtrace open <file.beamtrace> [--web|--tui]
beamtrace compare <left.beamtrace> <right.beamtrace>
beamtrace export <file.beamtrace> --format html|jsonl|mermaid|otlp
beamtrace serve
beamtrace relay <https-hub-url> --enroll <one-time-token>
beamtrace tui [--server <url>]
beamtrace doctor
beamtrace mcp
```

Exit codes are `0` success, `1` comparison/diagnostic policy failure, `2` usage/connect/configuration error, `3` incomplete capture, and `4` permission or safety refusal.

## Safety defaults

- OTP isolated trace sessions avoid changing another tracer's flags.
- Exact capture refuses to replace an occupied system tracer.
- Metadata mode exports term tags, shapes, sizes, and salted fingerprints—not scalar or binary values.
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

CI runs OTP 27–29 on Windows, Linux, and macOS, plus shortname, longname, and TLS distribution suites. See [development.md](docs/development.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [repository governance](docs/github-governance.md).

Questions belong in [GitHub Discussions](https://github.com/P4suta/beamtrace/discussions/categories/q-a), confirmed defects use the structured issue forms, and suspected vulnerabilities use a private security advisory. See [SUPPORT.md](SUPPORT.md), [SECURITY.md](SECURITY.md), and [GOVERNANCE.md](GOVERNANCE.md).

Tagged releases build six native OS/architecture archives, a Hex tarball for `beamtrace_core`, Homebrew and Scoop metadata, and a GHCR OCI image. Archives contain checksums and SPDX SBOM data; GitHub OIDC artifact attestations record build provenance.

## License

BeamTrace is dual-licensed under your choice of [Apache-2.0](LICENSES/Apache-2.0.txt) or [MIT](LICENSES/MIT.txt). The repository follows REUSE metadata conventions.
