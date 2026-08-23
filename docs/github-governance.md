<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# GitHub repository governance

Repository settings are treated as versioned policy. The canonical branch and tag rulesets live in `.github/rulesets`, while `scripts/configure-github.ps1` applies the complete remote policy and `scripts/audit-github.ps1` verifies it without mutation.

## Required change path

The default branch rejects deletion, force-pushes, unsigned commits, merge commits, and direct routine changes. Pull requests require resolved review threads plus current-base `TDD Gate`, `Release Candidate Gate`, `Dependency review`, and `CodeQL / JavaScript` checks. Pull request titles must use `type(scope): subject`, and only squash merges are enabled.

BeamTrace currently has one maintainer, so the ruleset requires zero approving reviews and has no branch bypass actor. GitHub does not allow a pull request author to approve their own change; requiring an independent approval before a second maintainer exists would make the normal merge path impossible. CODEOWNERS still documents responsibility, and review-thread resolution remains mandatory whenever review occurs. Once at least two active maintainers exist, increasing the approval count and enabling code-owner and last-push approval should be proposed as a reviewed policy change.

Release tags matching `v*` cannot be rewritten or deleted without an explicit administrator bypass. Publishing jobs use the `release` environment, which accepts only matching tags. Release PR automation uses a separate `release-automation` environment restricted to `main`; the GitHub App is installed only on this repository and receives Contents, Pull requests, and Issues read/write permissions.

## Supply-chain and security controls

- Workflows default to read-only token permissions and elevate only per job.
- Third-party Actions are allow-listed and every Action reference is pinned to a full commit SHA.
- Dependabot groups weekly npm and GitHub Actions updates.
- Pull requests receive dependency review; JavaScript boundaries receive CodeQL analysis; OpenSSF Scorecard runs weekly.
- Fast-check exercises arbitrary Unicode and control-character input at the Web API query boundary as part of the Chromium acceptance gate.
- Dependency alerts, automated security updates, private vulnerability reporting, secret scanning, and push protection are enabled remotely.
- Repository Actions cannot approve pull requests.

Gleam and Hex dependencies are not currently supported by Dependabot, so their locked dependency changes remain part of the normal TDD review path.

## Applying and auditing

Authenticate `gh` as a repository administrator, then run:

```powershell
./scripts/configure-github.ps1 -Repository P4suta/beamtrace -ReleasePleaseAppClientId '<client-id>'
./scripts/audit-github.ps1 -Repository P4suta/beamtrace
```

The configure script is idempotent: it updates metadata, topics, labels, Actions permissions, security controls, both release environments, the App client ID variable, and named rulesets. Private keys and API keys remain manual environment secrets. The audit script exits non-zero on policy drift. Local policy structure is covered by `scripts/test-repository-governance.ps1` and the normal `scripts/test-all.ps1` gate. See [releasing.md](releasing.md) for the complete setup and failure contract.

Ruleset behavior follows [GitHub's repository rulesets documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets). Action allow-list and SHA-pinning behavior follows the [GitHub Actions permissions API](https://docs.github.com/en/rest/actions/permissions).
