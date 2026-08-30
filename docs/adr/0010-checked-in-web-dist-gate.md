<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0010 — The checked-in Web distribution must reproduce from source

Status: Accepted · 2026-08-30

## Context

`packages/beamtrace_web/dist/` is committed and copied into the native archive, but nothing verified that it matched `src/`; a stale bundle would ship silently.

## Decision

`scripts/test-web-dist.ps1` (in `test-all.ps1` after `build-web.ps1`) and `scripts/test-unit.sh` rebuild the bundle and fail when `git status` reports a change under `dist/`. The build was verified to be byte-reproducible before enabling the gate.

## Consequences

Web changes must be committed together with their rebuilt `dist/`; CI rejects drift.
