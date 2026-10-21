---
doppler_automation_app: release_please
---

# Credential delivery

GitHub Actions exchanges its workload identity for a short-lived Doppler token at the credential-consuming step.
Each purpose has its own read-only service account, config, and environment variable.
Shared signing credentials stay in the canonical signing project and are referenced from the consumer config.
The shared credential still carries the signing provider's authority after retrieval.

| Purpose | Doppler config | GitHub environment variable | Environments |
| --- | --- | --- | --- |
| automation | `beamtrace.automation` | `DOPPLER_AUTOMATION_IDENTITY_ID` | release-automation |

The manual **Verify credential access** workflow checks required fields and rejects access to an unrelated config.
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
Use the registry's native trusted publisher where supported; an unconfigured publisher stays unavailable until its owner configures the exact binding.

Store only field names, identity metadata, source revisions, and verification outcomes in issues and logs.
Keep credential values and native authentication state out of the repository.

## Hex publisher

Hex uses its own native Workload Identity for `beamtrace_core` in `release.yml` and the protected `release` environment.
The package owner must configure the exact production binding with two-factor authentication.
The Rust adapter in `release-tools` validates the expected repository IDs, HTTPS OIDC origin, package scope, Bearer token type, and bounded lifetime before giving the token to Gleam.
It keeps tokens out of arguments, files, workflow outputs, and logs, and removes GitHub OIDC request credentials from the child.
Its explicit `--check` mode never starts the publisher.
Build and run its tests, Clippy, Kani proofs, and assertion-counterexample gate through `mise run test:release-tools` without contacting the authentication endpoints.

Kani proves the production dispatch decision for both modes and both authentication states.
The HTTPS services, GitHub's signed identity, Hex's configured publisher verification, and Gleam's existing publishing behavior remain external trust boundaries.
Real identity exchange and package publication need their own source-bound evidence and authorization.
Package existence and publisher registration remain pending until the owner checks them.
No first-publication bootstrap or replacement static key forms part of this migration.
