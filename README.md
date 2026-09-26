<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# BeamTrace

[![TDD](https://github.com/P4suta/beamtrace/actions/workflows/ci.yml/badge.svg)](https://github.com/P4suta/beamtrace/actions/workflows/ci.yml)
[![Security](https://github.com/P4suta/beamtrace/actions/workflows/security.yml/badge.svg)](https://github.com/P4suta/beamtrace/actions/workflows/security.yml)

BeamTrace records one bounded causal operation from Gleam, Elixir, or Erlang,
then explains what was observed, what was inferred, and where evidence ends.
It does not add an RPC shell, process mutation, process killing, or an ETS
browser.

## Install

### Native ZIP (recommended CLI)

Download the archive for your platform from the
[GitHub release](https://github.com/P4suta/beamtrace/releases):

- `beamtrace-<version>-linux-x64.zip`
- `beamtrace-<version>-linux-arm64.zip`
- `beamtrace-<version>-macos-x64.zip`
- `beamtrace-<version>-macos-arm64.zip`
- `beamtrace-<version>-windows-x64.zip`

Each self-contained archive includes ERTS. Download its adjacent `.sha256`
file, verify the checksum, and verify the GitHub artifact attestation before
running it:

```sh
VERSION=0.3.0 # x-release-please-version
TARGET=linux-x64
sha256sum --check beamtrace-${VERSION}-${TARGET}.zip.sha256
gh attestation verify beamtrace-${VERSION}-${TARGET}.zip --repo P4suta/beamtrace
unzip beamtrace-${VERSION}-${TARGET}.zip
./beamtrace-${VERSION}-${TARGET}/bin/beamtrace version
```

On Windows, use `Get-FileHash -Algorithm SHA256` and compare it with the
downloaded checksum file. The release page is the source of truth; BeamTrace
does not currently advertise an unpublished Homebrew tap or Scoop bucket.

### Gleam library

Add the target-independent package from Hex:

```sh
gleam add beamtrace_core
```

The high-level `beamtrace` module validates events, constructs the causal DAG
once, and exposes checked comparison on both Erlang and JavaScript. See the
[`beamtrace_core` guide](packages/beamtrace_core/README.md).

### OCI

The release workflow publishes immutable version and commit tags to
`ghcr.io/p4suta/beamtrace`. Pin the digest reported by your verified release:

```sh
docker pull ghcr.io/p4suta/beamtrace@sha256:DIGEST
docker run --rm ghcr.io/p4suta/beamtrace@sha256:DIGEST version
```

## 60-second demo

From an extracted native archive:

```sh
beamtrace demo
```

BeamTrace records its bundled fixture, binds an OS-selected loopback port, and
opens a one-time bootstrap URL in the default browser. If the browser cannot be
opened, the URL is printed and the server continues. Use `--no-open` to print
the URL deliberately, or use this CI-safe command:

```sh
beamtrace demo --no-ui --json
```

Without `--out`, the demo archive is temporary and removed when the command
ends. Keep it explicitly with `--out demo.beamtrace`.

## Record a real application

Choose the MFA that represents the operation and put the application command
after `--`. Output defaults to an exclusively created
`beamtrace-YYYYMMDDTHHMMSSZ[-N].beamtrace` file.

### Gleam

```sh
beamtrace record --trigger app:main/0 -- gleam run
```

### Elixir

```sh
beamtrace record --trigger Elixir.MyApp.Worker:run/1 -- mix run
```

### Erlang

```sh
beamtrace record --trigger orders_worker:run/1 -- rebar3 shell
```

Interactive terminals use the Web result workspace by default; non-interactive
runs use no UI. Override that choice with `--web`, `--tui`, `--no-ui`, or
`--no-open`. Progress reports connection, arming, observation end, sealing,
verification, and the final path.

Recording from an already running node is equally direct:

```sh
beamtrace capture app@host --trigger shop:checkout/1
```

Exact capture uses VM-global `seq_trace`. An interactive terminal explains and
asks once immediately before execution. Non-interactive automation must make
the existing explicit acknowledgement:

```sh
beamtrace capture app@host \
  --trigger shop:checkout/1 \
  --acknowledge-seq-trace-reset \
  --json
```

An existing destination is never replaced implicitly. Pass a different path,
or use `--force` only when replacement is intentional.

## Read a result

The result overview comes before the event table and reports:

- why observation ended;
- whether final delivery receipts verify the captured set;
- integrity issues and causal boundaries;
- the evidence basis for every Exact or Inferred relationship;
- what the trace cannot establish.

See [Reading results](docs/reading-results.md) for the interpretation contract.
Clock calibration remains an interval, quiet time is not a completeness claim,
and ambiguous comparison alignment remains explicit.

## CLI and API

Run `beamtrace` with no arguments for the short path, or use generated help and
completion from the declarative command specification:

```sh
beamtrace help compare
beamtrace capture --help
beamtrace completion bash
beamtrace completion zsh
beamtrace completion fish
beamtrace completion powershell
```

`compare` accepts 2–20 archives and supports Web, TUI, and JSON modes:

```sh
beamtrace compare run-1.beamtrace run-2.beamtrace run-3.beamtrace --web
```

Finite commands accept `--json` and emit one stdout object containing
`schema_version`, `command`, `ok`, `exit_code`, `artifact`, `outcome`, and
`error`. Human errors provide a stable code, explanation, and next action.

The supported HTTP surface is `/api/v2`; its OpenAPI 3.1 document is included
in the distribution and served at `/api/v2/openapi.json`. `/api/v1` remains a
deprecated compatibility projection through v0.3 and advertises removal in
v0.4.

References:

- [Getting started](docs/getting-started.md)
- [Gleam recording](docs/record-gleam.md), [Elixir recording](docs/record-elixir.md), [Erlang recording](docs/record-erlang.md)
- [CLI reference](docs/cli-reference.md), [API reference](docs/api-reference.md), [MCP reference](docs/mcp-reference.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Archive format](docs/trace-format.md), [threat model](docs/threat-model.md), [Team mode](docs/team-mode.md)

## Safety defaults

- Metadata capture is the default; raw capture retains its separate, bounded
  authorization and redaction policy.
- Distribution cookies, bootstrap tokens, OIDC material, grants, and raw
  payloads are not persisted in command configuration or logs.
- Archives reject unsafe paths, duplicate entries, suspicious compression,
  excessive size, checksum mismatch, non-canonical events, and invalid DAGs.
- Local Web binds loopback and exchanges a one-time URL for an HttpOnly,
  SameSite cookie.
- There is no telemetry, CDN, external font, or usage tracking.

## Development

Tool versions and standard tasks are pinned in [`.mise.toml`](.mise.toml):

```sh
mise install
mise run test
```

`mise run test:unit` avoids external sockets and optional ecosystems;
`mise run test:integration` owns the socket, EPMD, Rebar3, and Mix runtime
tests and reports missing optional tools as skipped prerequisites rather than
code failures. The release gate still runs OTP 27–29, five native archives,
distribution/TLS/S3/Chromium/PTY/MCP, performance, and archive-size checks.

See [Development](docs/development.md), [Contributing](CONTRIBUTING.md), and
[Release procedure](docs/releasing.md).

## License

BeamTrace is dual-licensed under your choice of
[Apache-2.0](LICENSES/Apache-2.0.txt) or [MIT](LICENSES/MIT.txt).
