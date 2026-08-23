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
4. The tag workflow refuses to proceed unless exactly one matching GitHub Release is both draft and prerelease. It lists releases explicitly because GitHub's release-by-tag endpoint only returns published releases, then builds and attests every artifact before any registry write.
5. The workflow publishes or verifies the immutable Hex package, then publishes or verifies GHCR tags `X.Y.Z` and `sha-<commit>` at one digest. Gleam requires the exact `I am not using semantic versioning` acknowledgement for every `0.x` publish even with `--yes`; the automation supplies it only after the release pull request approval and immutable tarball comparison.
6. A clean exact-version Hex consumer build, HexDocs request, and registry-pulled OCI `version`, `doctor`, and non-root checks must pass.
7. Only then are the release assets uploaded with replacement enabled and the existing draft published as `BeamTrace vX.Y.Z`.

If any step fails, the GitHub Release remains a draft. A rerun may skip an existing Hex version only when its parsed metadata values match after normalizing unordered metadata collections and all expanded file names and hashes match exactly. It may reuse GHCR tags only when the source revision, image identity, and final digest match. The workflow never uses Hex `--replace` and never creates `latest`.

If an existing registry object differs, stop. Do not rewrite the tag or package; repair the automation and issue a patch release.

If the tag workflow fails before any registry write because its workflow definition is defective, the already-approved immutable tag may be recovered without moving it. First verify that the GitHub Release is still an empty draft, Hex and GHCR have no version, and the tag still resolves to the release pull request merge commit. Merge a reviewed automation fix, temporarily allow the protected `main` branch in the `release` environment, and manually dispatch the Release workflow with both the existing tag and its full commit SHA. The workflow resolves the tag independently, refuses a mismatch, and checks out that exact commit for every source build. For publication, it keeps that source in `release-source` while checking out the exact `github.workflow_sha` into `release-tools`; the reviewed tooling receives the immutable source root explicitly and cannot silently substitute `main` application source. Remove the temporary `main` environment policy immediately after every environment-protected publication job completes. This recovery path reuses the release pull request's human approval; it must never be used to substitute different source for an approved tag.
