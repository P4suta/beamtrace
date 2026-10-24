---
doppler_automation_app: release_please
---

# Credential delivery

GitHub Actions exchanges its workload identity for a short-lived Doppler token at the credential-consuming step.
Each purpose has its own read-only service account, config, and environment variable.
The release App stays in the canonical automation project and is referenced from the consumer config.
The Hex package token stays in this repository's dedicated publishing config.
Retrieved credentials retain their provider permissions, so minted App tokens and the Hex key also need narrow scopes.

| Purpose | Doppler config | GitHub environment variable | Environments |
| --- | --- | --- | --- |
| automation | `beamtrace.automation` | `DOPPLER_AUTOMATION_IDENTITY_ID` | release-automation |
| publish_hex | `beamtrace.release` | `DOPPLER_HEX_IDENTITY_ID` | release |

The manual **Verify credential access** workflow checks automation credentials and rejects access to an unrelated config.
Automation also creates a repository-scoped App token with contents read access.
This workflow performs no signing, notarization, registry publication, release creation, or deployment.
Existing environment protections remain in force; their approval does not grant authority for another operation.

After the reviewed workflows reach the default branch, run the credential-access check for that exact revision.
Keep the current credential delivery until every purpose and environment succeeds and the denial checks pass.
Confirm an explicit access-denied response for each negative check.
Keep the selected identity fixed for that scope check.
A workflow can exchange for every identity whose claims it satisfies; separate accounts alone don't isolate stages with matching claim policies.
Network, authentication, and runner failures leave that evidence inconclusive.
Then disconnect the corresponding Doppler-to-GitHub sync while preserving its target fields, check for remaining consumers, and remove the obsolete GitHub fields and legacy configs.
An expired or revoked registry key is a retirement candidate and must not be copied into a replacement config.
The owner has selected a stored package token for Hex while its native Workload Identity registration is unavailable.

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
Reconsider native Hex Workload Identity only after its production availability and the exact package binding are confirmed.
