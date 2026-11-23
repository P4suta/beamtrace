<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0019 — Environment variables have a three-tier contract

Status: Accepted · 2026-09-01

## Context

Shipped code reads more than forty `BEAMTRACE_*` variables, but only the Team/OIDC/S3 subset was documented, scattered across `docs/team-mode.md`. Users could not tell a supported knob (`BEAMTRACE_COOKIE_FILE`) from wrapper IPC internals (`BEAMTRACE_RECORD_*`), and nothing failed when a variable was added without documentation.

## Decision

- `docs/environment-variables.md` is the single reference, in three tiers: user contract (CLI knobs with defaults and accepted values), Team server configuration (the `serve` process environment; `team-mode.md` links here instead of duplicating), and internal reserved prefixes declared as `BEAMTRACE_<PREFIX>_*` rows — setting those is unsupported and carries no compatibility promise.
- `scripts/check-env-docs.mjs` (run by `test-docs.ps1`) enforces the contract both ways: every variable read by shipped sources must be documented or match a declared internal prefix, and every documented variable must still be read somewhere. Test-only variables live outside shipped source roots and are exempt.
- New variables therefore ship with their documentation in the same change, or CI fails.

## Consequences

Adding an internal variable means extending an existing reserved prefix or declaring a new one in the reference; adding a user knob means writing its row. Renames surface as a stale-row failure.
