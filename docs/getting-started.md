<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Getting started

## 1. Verify the installation

Use a checksum- and attestation-verified native ZIP from the GitHub release,
then run:

```sh
beamtrace version
beamtrace doctor
```

The ZIP includes ERTS. Source development instead uses the versions pinned in
`.mise.toml` and runs the CLI with `mise run beamtrace -- <command>`.

## 2. Run the demo

```sh
beamtrace demo
```

The default Web workspace uses an OS-selected loopback port and a one-time
bootstrap URL. `--no-open` prints the URL. `beamtrace demo --no-ui --json` is
deterministic in CI. The unnamed demo archive is deleted when the command ends.

## 3. Record one operation

```sh
beamtrace record --trigger app:main/0 -- gleam run
```

Put every child-command argument after `--`; BeamTrace starts it directly and
does not use a shell. The archive path is generated exclusively. An explicit
existing path is rejected unless `--force` is present.

## 4. Validate and compare

```sh
beamtrace validate beamtrace-20260830T120000Z.beamtrace
beamtrace compare before.beamtrace after.beamtrace --tui
```

Compare accepts 2–20 traces. Alignment excludes PIDs and clock origins, and
reports ambiguity and first divergence rather than forcing a match.

Next: [Reading results](reading-results.md) and the language-specific recording
guides.
