---
date: 2026-11-09
status: proposed
---

# Sync release App credentials to the protected environment

Status: `Proposed`

## Context

Doppler's [identity limit](https://docs.doppler.com/docs/platform-limits) constrains fleet growth, while release automation already uses an environment restricted to main.

## Decision

Use [native GitHub synchronization](https://docs.doppler.com/docs/github-actions) from a purpose-specific config to named secrets in release-automation.
Pass credentials only to the pinned App token action, with explicit repository and permission inputs, and verify its consumer contract locally.

## Alternatives

Doppler OIDC avoids GitHub copies and keeps workflow and event claims but needs identity capacity, while a service token needs rotation.

## Consequences

GitHub stores copies of the shared App key, so protected main and environment policies guard installation-wide authority.
Reconsider when the App supports workload identity or environment restrictions change.

## Confirmation

Verify synchronization and read-only App authentication from reviewed main before identity retirement, preserve Hex publishing OIDC, and pause the proposal workflow during migration without creating a release or tag.
