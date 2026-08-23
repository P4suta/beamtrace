<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Governance

BeamTrace is currently maintained by [@P4suta](https://github.com/P4suta). The maintainer owns releases, security response, project scope, and final decisions on public contracts.

Changes are developed test-first. Public-contract, trace-semantics, privacy, storage, or protocol changes should start with an issue and a concrete failing acceptance example. Routine fixes can proceed directly to a pull request.

Decisions favor evidence, bounded impact on observed nodes, explicit uncertainty, metadata privacy, and compatibility with OTP 27–29. Material decisions are recorded in an issue, pull request, or versioned document rather than in a private channel.

Additional maintainers may be invited after sustained, constructive contributions and demonstrated care for the security boundaries. No contribution volume automatically grants access. Repository and release permissions follow least privilege and can be removed when they are no longer needed.

Security reports follow [SECURITY.md](SECURITY.md). Conduct follows [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). While BeamTrace has one maintainer, changes still require a pull request, signed commits, resolved review threads, and all required test and security checks, but not an impossible self-approval. The main-branch ruleset has no bypass actor. The approval policy should be raised through a reviewed policy change when a second active maintainer joins.
