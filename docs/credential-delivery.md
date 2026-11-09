---
doppler_automation_app: release_please
---

# Credential delivery

The release App stays in the canonical shared Doppler config, with references in `beamtrace.automation`.
A purpose-specific config, `beamtrace.github_automation`, maps the approved fields to `RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY`.
[Native GitHub synchronization](https://docs.doppler.com/docs/github-actions) writes the named secrets to the release-automation environment.
The [sync manifest](../automation/release-app-sync.toml) binds the destination repository and owner IDs, environment, main branch policy, and field mapping.

Restrict release-automation to main and turn off administrator bypass.
Protected main and environment policies guard the GitHub copies instead of Doppler workflow and event claims.
The shared App key still grants authority across its installations, even when the installation token has a narrower scope.
Pass the named secrets only to the pinned official App token action with explicit owner, repository, and permissions.
Reject missing values and unresolved references before minting a token.
The action revokes its token after the job.

The manual **Verify credential access** workflow creates only a token restricted to `P4suta/beamtrace` with contents read access.
It accepts only a manual dispatch from main in the expected repository and protected environment.
It performs no checkout, signing, registry publication, release creation, or deployment.
The release contract parses both App workflows and rejects broader permissions, other secret consumers, changed trust conditions, and token revocation bypasses.
Run `npm run test:release-credentials` locally through `scripts/test-release.ps1`.

Before merging the migration, verify the sync destination, enabled state, and successful first synchronization without reading values.
Pause the proposal workflow during the merge, dispatch the read-only check from the exact reviewed main commit, and confirm token revocation.
Restore the proposal workflow after the check and read back its active state.
Keep the previous App delivery identity and public variable until a separate retirement review checks every remaining consumer.
Migration grants no authority to merge a release pull request or publish a tag.

Hex publishing keeps Doppler OIDC through `beamtrace.release`, the release environment, and `DOPPLER_HEX_IDENTITY_ID`.
Use only a current package token with verified provider permissions.
Store only field names, identity metadata, source revisions, and verification outcomes in issues and logs.
Keep credential values and native authentication state out of the repository.

## Hex publisher

The owner stores a key restricted to `beamtrace_core` in `beamtrace.release.HEXPM_API_KEY` and maintains its lifetime and rotation.
Use the package permission without broad API or repository permissions.
An expired, revoked, or unverified old key doesn't become active through this configuration change.
The owner supplies a current key through Doppler without sending its value through chat or the repository.
Prepare the workflow and configuration before issuing a key.
Key registration, delivery identity setup, and live delivery checks belong to the preparation for a future authorized release.
An inactive Hex publisher doesn't block verification of the release automation App.

The read-only Hex delivery identity can read only `beamtrace.release`.
Bind its OIDC policy to the immutable repository and owner IDs, the `release` environment, `release.yml`, and the manual `verify-hex.yml` workflow.
The publisher fetches this config after artifact preparation and passes only `HEXPM_API_KEY` to the publishing step.
The publishing script rejects an empty or unresolved key and keeps the existing immutable package comparison before calling Gleam.
This is the selected authentication method, with no automatic switch to a saved login or another key.

The manual **Verify Hex credential delivery** workflow checks credential retrieval and config isolation without calling the publisher or a registry write endpoint.
Run it only after the owner prepares the key and its delivery identity.
That check establishes delivery, while key permissions, lifetime, and revocation require provider-side evidence.
Publication remains a separate authorized operation.
Reconsider native Hex Workload Identity only after confirming its production availability and the exact package binding.
