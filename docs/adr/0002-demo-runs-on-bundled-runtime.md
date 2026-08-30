<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0002 — Demo runs on the bundled runtime; record runs on the user's toolchain

Status: Accepted · 2026-08-30

## Context

`beamtrace demo` passed `-pa <path inside lib/beamtrace.escript>` to a child `erl`, so the packaged archive could not load `beamtrace_demo_fixture` and left `erl_crash.dump` in the working directory. The bundled ERTS is trimmed to eight OTP applications and must never become the runtime of a recorded application; `record_child_environment/1` restores the parent `PATH`, `ERL_ROOTDIR`, and `ERL_LIBS` for that reason.

## Decision

- `demo` resolves `erl` from the running VM's `bindir` and stages `beamtrace_demo_fixture.beam` into the private record gate directory next to `guard.beam` (`start_gated_command/5`, `beamtrace_` modules only, mode 0600, deleted with the gate). The child gets `-pa <gate dir>` and `ERL_ROOTDIR=code:root_dir()`.
- `record` keeps launching the application on the toolchain found in the user's `PATH`; the bundled ERTS is never prepended to `PATH`.
- Every record child writes `ERL_CRASH_DUMP` into the gate directory unless the user set it explicitly; the dump `Slogan` line is appended to the output tail and the file is removed with the gate.

## Consequences

The packaged demo works without a host Erlang and is gated by `scripts/test-package.ps1`. Recorded applications keep their own runtime. Crash dumps of BeamTrace-launched children are summarised, not preserved.
