<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Troubleshooting

## The browser did not open

The server remains running. Open the printed one-time bootstrap URL, or rerun
with `--no-open`. Confirm the bind line appears before using the URL.

## `system_tracer_occupied`

Another tracer owns the VM-global facility. Stop that tracer and retry, or use
Live for bounded inferred sampling. BeamTrace never replaces the owner.

## The target cannot connect

Run `beamtrace doctor`, check longname/shortname agreement, DNS/hosts entries,
EPMD reachability, distribution TLS settings, and that the private cookie file
contains the same value. Cookie values are not accepted as CLI arguments.

## The selected MFA never fires

Confirm the canonical `Module:function/arity` with MFA search, arm immediately
before one operation, and increase only the relevant bounded window. AQL,
preset, and root count are under Advanced in the Web capture screen.

## The archive already exists

Generated output names are exclusive and add a numeric suffix. For an explicit
path, choose another path or pass `--force` only when replacement is intended.

## Integrity issues or boundaries appear

Read the named issue and delivery status before interpreting events. Repair the
missing node, drop, receipt, or drain condition and record again. Boundaries and
uncalibrated time cannot be recovered from the existing archive.

## An optional development tool is missing

Run `mise install`. Unit tasks do not require Mix, EPMD sockets, Chromium, S3,
Docker, or a PTY. Integration tasks print skipped prerequisites separately;
release CI supplies and tests every required environment.
