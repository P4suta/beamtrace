<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Record Gleam

Choose a public or internal MFA reached once by the operation:

```sh
beamtrace record --trigger app:main/0 -- gleam run
beamtrace record --trigger checkout:handle/1 --no-ui -- gleam run
```

Gleam recording requires the Erlang target. BeamTrace performs a bounded build
when the trigger BEAM is absent, creates an isolated node and ephemeral cookie,
arms before releasing the project VM, then seals and validates the archive.

For a long-running existing node, use `capture` with the node name and a private
cookie file. Non-interactive exact capture also requires
`--acknowledge-seq-trace-reset`.
