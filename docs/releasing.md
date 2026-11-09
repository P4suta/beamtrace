<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Release process

BeamTrace `0.x` releases are alpha prereleases.
Merging a release pull request is the sole human approval that may start publication.
Remove the `prerelease` setting through a reviewed change before `v1.0.0`.

## One-time repository setup

Reuse the reviewed release-please App through the canonical shared Doppler config.
Sync only `RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY` from the purpose-specific `beamtrace.github_automation` config to `release-automation`.
Restrict the environment to `main` and turn off administrator bypass.
Restrict minted App tokens to `P4suta/beamtrace` and the reviewed Contents, Pull requests, and Issues permissions.

Keep `release` restricted to tags matching `v*`, and set `DOPPLER_HEX_IDENTITY_ID` to the read-only identity for `beamtrace.release`.
Store a current Hex key restricted to package `beamtrace_core` as `HEXPM_API_KEY` in `beamtrace.release`.
Exclude broad API and repository permissions.
Enable GitHub release immutability before merging a release pull request, because it protects only future releases.

Complete Hex key registration and its delivery identity setup before a future authorized release.
Preparing code and configuration requires no active publishing credential.
The owner maintains the Hex key's lifetime and rotation through the provider and Doppler.
This workflow uses the selected package-token method and rejects missing credentials.
See [credential delivery](credential-delivery.md) for the staged cutover and authentication-only checks.

Apply the environment and branch policies after preparing the scoped Hex identity:

```powershell
./scripts/configure-github.ps1 `
  -Repository P4suta/beamtrace `
  -DopplerHexIdentityId '<hex-identity-id>'
./scripts/audit-github.ps1 -Repository P4suta/beamtrace
```

The GitHub App token action uses the two named environment secrets synchronized from Doppler.
The release-please workflow explicitly requests only the three reviewed App permissions.
The manual **Verify credential access** workflow checks only read-only App authentication from reviewed main.
It checks no publishing credentials and performs no publication.
The Hex job fetches `HEXPM_API_KEY` through Doppler OIDC and exposes it only to the publishing step after artifact preparation.
The manual **Verify Hex credential delivery** workflow checks delivery and config isolation without publishing after the key and identity are ready.
For a check from `main`, permit that branch in the existing `release` environment only for the verification window and restore its tag policy afterward.
A passing delivery check doesn't establish the Hex key's publish authority.
Verify its package permission, lifetime, and revocation status in Hex before a future authorized release.

## Bootstrap state

Before the first release, `.release-please-manifest.json` is `{}` and `CHANGELOG.md` is empty.
Omitting `bootstrap-sha` lets the first release pull request derive the `v0.1.0` notes from all Conventional Commits in repository history.
The `simple` strategy owns the plain `version.txt` version file.
Keep every package version, local lockfile version, and runtime version constant synchronized with it.
The manifest JSONPath uses `source.value` because the pinned release-please TOML updater exposes parsed scalar values through that field.
The acceptance test confirms that only `source = "local"` entries change.

The setup pull request title is:

```text
feat(ci): automate releases with release-please
```

All later pull request titles must use `type(scope): subject`.
Squash merging preserves the title as the Conventional Commit consumed by release-please.

## Automated sequence

A push to `main` creates or updates the release pull request using the repository-scoped GitHub App token.
A pull request carrying `autorelease: pending` builds and smoke-tests all five supported native archives, the Hex tarball, the OCI image, and Homebrew/Scoop metadata without publishing anything.
Each ZIP must stay within 5% growth over its published v0.1.0 target baseline.
Exclude Windows ARM64 until CI can provision and verify a native Erlang/OTP runtime.
Never publish the Windows x64 runtime under an ARM64 artifact name.

Immediately before merging the release pull request, rerun `audit-github.ps1` with a repository administrator token and require immutable releases to remain enabled.
GitHub's endpoint requires the repository `Administration: read` permission, which the workflow token lacks, so the audit belongs to the human publication gate.
Merging the release pull request lets release-please create a protected `vX.Y.Z` tag and a draft GitHub prerelease.

The tag workflow requires exactly one matching GitHub Release with both draft and prerelease states, plus a runner that supports immutable-release attestation verification.
It lists releases explicitly because GitHub's release-by-tag endpoint returns only published releases.
It then builds and attests every artifact before any registry write.

The workflow publishes or verifies the immutable Hex package, then publishes or verifies GitHub Container Registry tags `X.Y.Z` and `sha-<commit>` at one digest.
Gleam requires the exact `I am not using semantic versioning` acknowledgement for every `0.x` publish even with `--yes`.
The automation supplies the acknowledgement only after the release pull request approval and immutable tarball comparison.
A clean exact-version Hex consumer runs the public codec, directed acyclic graph, and diagnostics example on both Erlang and JavaScript.
A HexDocs request and registry-pulled OCI `version`, `doctor`, and non-root checks must also pass.

After verification, the workflow uploads the exact release assets to the existing draft.
It rechecks their names, sizes, GitHub-reported SHA-256 digests, and protected tag SHA immediately before publication.
It publishes the draft as `BeamTrace vX.Y.Z` only when GitHub reports the resulting release as immutable, then verifies its release attestation.

If any step fails, the GitHub Release remains a draft.
A rerun may skip an existing Hex version only when its parsed metadata values match after normalizing unordered metadata collections and all expanded file names and hashes match exactly.
Reusing GitHub Container Registry tags requires revision and version labels that match the immutable release inputs.
Both tags must also resolve to the same registry digest and image config.
It creates a missing partner tag only from the validated existing image.
Timestamped Docker rebuild IDs don't determine published release identity.
The workflow never uses Hex `--replace` and never creates `latest`.

Stop if an existing registry object differs.
Repair the automation and issue a patch release without rewriting the tag or package.

If a workflow defect stops the tag workflow before any registry write, recover the approved immutable tag without moving it.
First verify that the GitHub Release remains an empty draft, Hex and GitHub Container Registry have no version, and the tag still resolves to the release pull request merge commit.
Merge a reviewed automation fix, temporarily permit protected `main` in the `release` environment, and manually dispatch the Release workflow with the existing tag and its full commit SHA.
The workflow resolves the tag independently, rejects a mismatch, and checks out the exact commit for every source build.
For publication, it keeps the source in `release-source` and checks out the exact `github.workflow_sha` into `release-tools`.
The reviewed tooling receives the immutable source root explicitly and can't substitute `main` app source.
Remove the temporary `main` environment policy immediately after every environment-protected publication job completes.
Recovery reuses the release pull request's human approval and must never substitute different source for an approved tag.
