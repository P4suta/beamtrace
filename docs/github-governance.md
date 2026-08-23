<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# GitHub repository governance

Repository settings are treated as versioned policy. The canonical branch and tag rulesets live in `.github/rulesets`, while `scripts/configure-github.ps1` applies the complete remote policy and `scripts/audit-github.ps1` verifies it without mutation.

## Required change path

The default branch rejects deletion, force-pushes, unsigned commits, merge commits, and direct routine changes. Pull requests require a code-owner approval, approval after the last push, resolved review threads, current-base testing, and the aggregate `TDD Gate` check. Only squash merges are enabled.

The repository administrator has a `pull_request`-only bypass. This exists so a sole maintainer is not permanently locked out by the independent-review rule. It does not permit a direct push, is visible in ruleset insights, and is reserved for recovery or the documented solo-maintainer case.

Release tags matching `v*` cannot be rewritten or deleted without an explicit administrator bypass. Publishing jobs use the `release` environment, which accepts only matching tags.

## Supply-chain and security controls

- Workflows default to read-only token permissions and elevate only per job.
- Third-party Actions are allow-listed and every Action reference is pinned to a full commit SHA.
- Dependabot groups weekly npm and GitHub Actions updates.
- Pull requests receive dependency review; JavaScript boundaries receive CodeQL analysis; OpenSSF Scorecard runs weekly.
- Dependency alerts, automated security updates, private vulnerability reporting, secret scanning, and push protection are enabled remotely.
- Repository Actions cannot approve pull requests.

Gleam and Hex dependencies are not currently supported by Dependabot, so their locked dependency changes remain part of the normal TDD review path.

## Applying and auditing

Authenticate `gh` as a repository administrator, then run:

```powershell
./scripts/configure-github.ps1 -Repository P4suta/beamtrace
./scripts/audit-github.ps1 -Repository P4suta/beamtrace
```

The configure script is idempotent: it updates metadata, topics, labels, Actions permissions, security controls, the release environment, and named rulesets. The audit script exits non-zero on policy drift. Local policy structure is covered by `scripts/test-repository-governance.ps1` and the normal `scripts/test-all.ps1` gate.

Ruleset behavior follows [GitHub's repository rulesets documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets). Action allow-list and SHA-pinning behavior follows the [GitHub Actions permissions API](https://docs.github.com/en/rest/actions/permissions).
