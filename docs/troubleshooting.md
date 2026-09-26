<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Troubleshooting

Every failure prints `beamtrace[E_CODE]: message` and a `Next:` line; the same
code and hint appear in `--json` output. `beamtrace help errors` lists them.

## The browser did not open

The server remains running. Open the printed one-time bootstrap URL, or rerun
with `--no-open`. Confirm the bind line appears before using the URL. The URL
is valid for 60 seconds after printing; when it has expired, rerun the
command to get a fresh one.

## `E_AGENT_BEAM_UNAVAILABLE`

The injected agent BEAM was not found, so nothing can be armed. From a release
archive, re-extract it and verify `checksums.sha256`. From source, run the CLI
through `mise run beamtrace -- <command>` (or `scripts/beamtrace.ps1`), which
builds the agent and sets `BEAMTRACE_AGENT_BEAM`.

## `E_COMMAND_NOT_FOUND`

`record` runs your application on the Erlang toolchain from `PATH`; the bundled
runtime only runs BeamTrace and `beamtrace demo`. Install Erlang/OTP 27–29 (and
Gleam, Mix, or Rebar3 as needed) or add them to `PATH`.

## `E_COOKIE_UNAVAILABLE`

The Erlang distribution cookie could not be prepared. Pass `--cookie-file`
pointing at a private, readable file, or set `BEAMTRACE_COOKIE`. For `record`,
BeamTrace can also create an ephemeral cookie when neither is given.

## `E_INVALID_CONFIGURATION`

`beamtrace.toml` failed validation; the offending field is named in the
detail. Fix it, then confirm with `beamtrace config check`.

## `E_TRACE_LOAD_FAILED`

An archive passed to `compare` could not be loaded. Run
`beamtrace validate <path>` on it — validation reports the precise integrity
or schema failure.

## `E_SYSTEM_TRACER_OCCUPIED`

Another tracer owns the VM-global facility. Stop that tracer and retry, or use
`beamtrace attach <node> --web` for bounded inferred sampling in the Live tab.
BeamTrace never replaces the owner.

## `E_TARGET_UNREACHABLE` or `E_TARGET_UNAVAILABLE`

Run `beamtrace doctor`, check longname/shortname agreement, DNS/hosts entries,
EPMD reachability, distribution TLS settings, and that the private cookie file
contains the same value. Cookie values are not accepted as CLI arguments. For
`record`, the child output tail is printed under the error.

## `E_CAPTURE_ARM_TIMEOUT` or `E_TRIGGER_TIMEOUT`

Confirm the canonical `Module:function/arity` (the Web capture screen suggests
MFAs as you type), arm immediately before one operation, and raise
`--capture-window SECONDS` (default 30, at most 300) when the operation takes
longer. AQL, preset, and root count are under Advanced in the Web capture
screen.

## `E_ARCHIVE_NOT_FOUND` or `E_OUTPUT_EXISTS`

Generated output names are exclusive and add a numeric suffix. For an explicit
path, choose another path or pass `--force` only when replacement is intended.
Archive paths are reported as `absolute_path` in `--json` output.

## Integrity issues or boundaries appear

Read the named issue and delivery status before interpreting events. Repair the
missing node, drop, receipt, or drain condition and record again. Boundaries and
uncalibrated time cannot be recovered from the existing archive.

## An optional development tool is missing

Run `mise install`. Unit tasks do not require Mix, EPMD sockets, Chromium, S3,
Docker, or a PTY. Integration tasks print skipped prerequisites separately;
release CI supplies and tests every required environment.
