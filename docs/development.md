<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Development

## Toolchain

- Gleam 1.18.x
- Erlang/OTP 27–29
- PowerShell 7 for repository scripts
- Elixir/Mix for the Elixir fixture
- OpenSSL only for the TLS distribution test
- Node.js/npm and Chromium for browser acceptance
- Docker for the real S3-compatible TLS and optional OCI/Linux Hex boundaries

`scripts/ensure-rebar3.ps1` downloads a checksum-pinned rebar3 executable when needed.

## Running from source

```sh
mise run beamtrace -- demo
mise run test        # unit + available integration + docs
mise run test:all    # the CI gate
```

`mise run beamtrace` builds the agent BEAM and sets `BEAMTRACE_AGENT_BEAM` and `BEAMTRACE_WEB_ROOT`; without them `record`, `capture`, and `demo` stop with `E_AGENT_BEAM_UNAVAILABLE`.

## Test commands

```powershell
./scripts/check-format.ps1
./scripts/test-core.ps1
./scripts/test-core-consumer.ps1
./scripts/test-runtime.ps1
./scripts/test-agent.ps1 -Distribution short
./scripts/test-agent.ps1 -Distribution long
./scripts/test-agent.ps1 -Distribution tls
./scripts/test-web.ps1
./scripts/test-tui.ps1
./scripts/test-tui-pty.ps1
./scripts/test-fixtures.ps1
./scripts/test-cli-smoke.ps1
./scripts/test-mcp.ps1
./scripts/test-package.ps1
./scripts/test-s3-dogfood.ps1
./scripts/test-hex-package.ps1
./scripts/test-distribution-metadata.ps1
./scripts/test-release.ps1
./scripts/test-web-e2e.ps1
./scripts/test-oci.ps1 -Build
./scripts/test-performance.ps1
./scripts/test-all.ps1
```

The narrow test should be used for Red/Green iteration. `test-all` is the portable local gate and includes Chromium unless `-SkipBrowserE2E` is supplied. Run `test-s3-dogfood.ps1` as the Docker-backed storage boundary. PTY acceptance runs on Linux; Windows validates its harness contract. Native Hex export runs on Linux because Gleam 1.18.1 rejects valid Windows paths during `hex-tarball`; `test-hex-package.ps1 -ContainerBoundary` exercises the Linux boundary from Windows when Docker is available.

CI repeats the non-browser gate across OTP 27–29 and three operating systems, exercises short/long/TLS distribution separately, runs real S3-compatible TLS, Chromium, the exact official MCP client, and PTY acceptance, and builds the actual OCI image. Record acceptance covers direct Erlang, a resolved Gleam shim, Rebar3, and Mix; the Elixir fixture job makes the otherwise optional Mix boundary mandatory. The isolated core consumer executes the README codec/DAG/diagnostics example on Erlang and JavaScript; the post-publication gate repeats it against the exact Hex version. Tag workflows require all package versions to match the tag, build and smoke-test five self-contained native archives, reject ZIP growth above 5% of the published v0.1.0 per-target baseline, and attest release subjects with GitHub OIDC. Windows ARM64 packaging remains disabled until CI has a reproducible native Erlang/OTP runtime.

The Linux performance gate runs with `+S 4:4` on OTP 27–29.
Core growth compares the median process reductions of three independent 25k and 50k runs against the existing threefold budget.
Each run uses a fresh monitored process and waits for its exit before the next run, so earlier heap state doesn't affect the measurement.
Elapsed time remains diagnostic for growth, and the 100k time and peak-memory ceilings remain in force.
The tracked workloads also cover a prepared baseline against multiple candidates, 100k capture normalization, 50k archive save/load/window and search, and a 128-event relay decode/ingest batch.
Prepared versus repeated analysis and selective versus full archive reads remain relative regression checks.

`scripts/test-performance.ps1` first exercises the real measurement helpers on every OS.
Its controls check worker isolation, failure propagation, median selection, the exact growth boundary, and rejection of zero or excessive work.
Opposing elapsed-time inputs check that scheduling delay can't change the work verdict.
The [Erlang process counter](https://www.erlang.org/doc/apps/erts/erlang.html#process_info/2) supplies the empirical work metric.
Reductions are runtime-specific work units, so results compare workloads within one pinned OTP runtime rather than counts across OTP versions.
They don't prove native-code cost or a complexity bound for arbitrary traces.
The real fixed workloads and absolute ceilings cover that measurement boundary; revisit the metric when Core delegates work to native code or child processes.

Changes carried in dependency forks are not automatically upstreamable.
[The upstream candidate ledger](upstream-candidates.md) records pinned SHAs,
missing evidence, and the approval gate; external issues, PRs, comments, and
branch pushes require a fresh evidence bundle and explicit repository-specific
user approval.

## Definition of done

- A failing test demonstrated the behavior before implementation.
- The narrow suite and `test-all` are green.
- Cleanup and incomplete-capture behavior are asserted for trace changes.
- Exact/inferred status is asserted for analysis changes.
- Bounds and malformed input are asserted for network/storage changes.
- User-visible or protocol changes update documentation and the changelog.
