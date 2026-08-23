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

## Test commands

```powershell
./scripts/check-format.ps1
./scripts/test-core.ps1
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
./scripts/test-all.ps1
```

The narrow test should be used for Red/Green iteration. `test-all` is the portable local gate and includes Chromium unless `-SkipBrowserE2E` is supplied. Run `test-s3-dogfood.ps1` as the Docker-backed storage boundary. PTY acceptance runs on Linux; Windows validates its harness contract. Native Hex export runs on Linux because Gleam 1.18.1 rejects valid Windows paths during `hex-tarball`; `test-hex-package.ps1 -ContainerBoundary` exercises the Linux boundary from Windows when Docker is available.

CI repeats the non-browser gate across OTP 27–29 and three operating systems, exercises short/long/TLS distribution separately, runs real S3-compatible TLS, Chromium, and PTY acceptance, and builds the actual OCI image. Tag workflows require all package versions to match the tag, build five self-contained native archives, and attest release subjects with GitHub OIDC. Windows ARM64 packaging remains disabled until CI has a reproducible native Erlang/OTP runtime.

## Definition of done

- A failing test demonstrated the behavior before implementation.
- The narrow suite and `test-all` are green.
- Cleanup and incomplete-capture behavior are asserted for trace changes.
- Exact/inferred status is asserted for analysis changes.
- Bounds and malformed input are asserted for network/storage changes.
- User-visible or protocol changes update documentation and the changelog.
