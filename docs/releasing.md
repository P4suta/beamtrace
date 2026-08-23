<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Releasing BeamTrace

BeamTrace `0.x` releases are alpha prereleases. Merging a release pull request is the sole human approval that may start publication; creating this automation does not itself authorize a tag or release. The `prerelease` setting must be removed through a reviewed change before `v1.0.0`.

## One-time repository setup

1. Create a GitHub App and install it only on `P4suta/beamtrace`.
2. Grant the App repository permissions for Contents, Pull requests, and Issues, each with read/write access. Do not grant organization-wide installation access.
3. Create the `release-automation` environment, restrict it to the `main` branch, add the environment variable `RELEASE_PLEASE_APP_CLIENT_ID` with the App client ID, and add the environment secret `RELEASE_PLEASE_APP_PRIVATE_KEY` containing the App private key.
4. Create the `release` environment, restrict it to tags matching `v*`, and add a short-lived `HEXPM_API_KEY` environment secret with API Write access only. The key must belong to the maintainer account intended to own `beamtrace_core`.
5. Confirm that the `beamtrace_core` Hex package name is still available immediately before approving the first release pull request.

The environment and branch policies can be applied idempotently after the secrets have been created:

```powershell
./scripts/configure-github.ps1 `
  -Repository P4suta/beamtrace `
  -ReleasePleaseAppClientId '<client-id>'
./scripts/audit-github.ps1 -Repository P4suta/beamtrace
```

The GitHub App token action uses the documented Client ID/private-key flow. The release-please workflow explicitly requests only the three reviewed App permissions.

## Bootstrap state

Before the first release, `.release-please-manifest.json` is `{}` and `CHANGELOG.md` is empty. There is intentionally no `bootstrap-sha`, so the first release pull request derives the `v0.1.0` notes from all Conventional Commits in repository history. The `simple` strategy owns the plain `version.txt` version file; every package and local lockfile version, and the runtime version constant, must remain synchronized with it. The manifest JSONPath uses `source.value` because the pinned release-please TOML updater exposes parsed scalar values through that field; its acceptance test confirms that only `source = "local"` entries change.

The setup pull request title is:

```text
feat(ci): automate releases with release-please
```

All later pull request titles must use `type(scope): subject`. Squash merging preserves that title as the Conventional Commit consumed by release-please.

## Automated sequence

1. A push to `main` creates or updates the release pull request using the repository-scoped GitHub App token.
2. A pull request carrying `autorelease: pending` builds all five supported native archives, the Hex tarball, the OCI image, and Homebrew/Scoop metadata without publishing anything. Windows ARM64 is excluded until CI can provision and verify a native Erlang/OTP runtime; the Windows x64 runtime must not be published under an ARM64 artifact name.
3. Merging that pull request lets release-please create a protected `vX.Y.Z` tag and a draft GitHub prerelease.
4. The tag workflow refuses to proceed unless the matching GitHub Release is both draft and prerelease. It builds and attests every artifact before any registry write.
5. The workflow publishes or verifies the immutable Hex package, then publishes or verifies GHCR tags `X.Y.Z` and `sha-<commit>` at one digest.
6. A clean exact-version Hex consumer build, HexDocs request, and registry-pulled OCI `version`, `doctor`, and non-root checks must pass.
7. Only then are the release assets uploaded with replacement enabled and the existing draft published as `BeamTrace vX.Y.Z`.

If any step fails, the GitHub Release remains a draft. A rerun may skip an existing Hex version only when its metadata and all expanded file hashes match. It may reuse GHCR tags only when the source revision, image identity, and final digest match. The workflow never uses Hex `--replace` and never creates `latest`.

If an existing registry object differs, stop. Do not rewrite the tag or package; repair the automation and issue a patch release.
