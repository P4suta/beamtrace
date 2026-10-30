<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Development

## Toolchain

Use the tool versions pinned in `.mise.toml` and PowerShell 7 for repository scripts.
The supported Erlang/OTP versions are 27, 28, and 29.
The Elixir fixture needs Elixir and Mix, and TLS distribution tests need OpenSSL.
Browser acceptance needs Node.js, npm, and Chromium.
Docker provides the real S3-compatible TLS, OCI, and Linux Hex boundaries.

`scripts/ensure-rebar3.ps1` downloads a checksum-pinned rebar3 executable when needed.

## Running from source

```sh
mise run beamtrace -- demo
mise run test
mise run test:all
```

`mise run beamtrace` builds the agent bytecode and sets `BEAMTRACE_AGENT_BEAM` and `BEAMTRACE_WEB_ROOT`.
An unavailable injected agent makes `record`, `capture`, and `demo` report `E_AGENT_BEAM_UNAVAILABLE`.
`mise run test` runs unit tests, available integration tests, and documentation checks.
`mise run test:all` runs the local gate without browser acceptance.

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

Use the narrow test for red and green iterations.
The complete local gate includes Chromium, and the `-SkipBrowserE2E` option omits the browser checks.
Run `test-s3-dogfood.ps1` for the Docker-backed storage boundary.
Terminal acceptance runs on Linux, and Windows validates its harness contract.
Native Hex export runs on Linux because Gleam 1.18.1 rejects valid Windows paths during `hex-tarball`.
When Docker is available on Windows, `test-hex-package.ps1 -ContainerBoundary` exercises the Linux boundary.

The TDD workflow runs a Linux fast gate for pull requests, merge groups, and manual dispatches.
Its five jobs check the title, unit tests, formatting, documentation, release configuration, and repository contracts before aggregating the results.
The workflow runs no archive matrix, browser installation, real image build, S3 service, or performance campaign for an ordinary pull request.

Release verification uses the immutable release SHA for every source checkout.
The compatibility matrix covers native runtime, process, socket, CLI, and terminal behavior on Linux, Windows, and macOS across OTP 27, 28, and 29.
Each Linux OTP job checks short, long, and TLS distribution, with every required protocol outcome checked before success.
The required Elixir fixture and Mix boundary, real S3-compatible TLS, Chromium, and bounded performance checks each run in one release lane.
Archive, Hex, OCI, and distribution-metadata checks run with the release artifact jobs.
Every publishing path requires the successful release verification gate.

Record acceptance covers direct Erlang, a resolved Gleam shim, Rebar3, and Mix.
The isolated core consumer executes the README codec, directed acyclic graph, and diagnostics example on Erlang and JavaScript.
The post-publication gate repeats the consumer check with the exact Hex version.
Release workflows require package versions to match the tag, smoke-test five self-contained native archives, enforce the existing ZIP size budgets, and attest release subjects with GitHub OIDC.
Windows ARM64 archives remain unavailable until CI has a reproducible native Erlang/OTP runtime.

The release performance gate runs once on Linux with `+S 4:4`.
For local acceptance on OTP 29, warm each workload and compare the median of three runs.
The workloads cover 100k Core analysis, prepared comparisons, and 100k capture normalization.
Archive workloads cover 50k events for saving, loading, windowing, and searching.
The relay workload decodes a 128-event batch and processes the resulting events.
Absolute ceilings remain conservative for shared CI runners.
Relative checks compare prepared with repeated analysis and selective with full archive reads as the primary regression signal.

Changes carried in dependency forks aren't automatically upstreamable.
[The upstream candidate ledger](upstream-candidates.md) records pinned SHAs, missing evidence, and the approval gate.
External issues, PRs, comments, and branch pushes require a fresh evidence bundle and explicit repository-specific user approval.

## Definition of done

A failing test demonstrates the behavior before implementation, and the narrow suite and `test-all` pass.
Trace changes assert cleanup and incomplete-capture behavior.
Analysis changes assert exact and inferred status.
Network and storage changes assert bounds and malformed input behavior.
User-visible and protocol changes update documentation and the changelog.
