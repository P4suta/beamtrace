<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Record Elixir

Use the BEAM module name, including the `Elixir.` prefix:

```sh
beamtrace record --trigger Elixir.MyApp.Worker:run/1 -- mix run
```

Arguments after `--` belong to Mix and retain their boundaries. BeamTrace does
not evaluate a shell command. If the module is not built, the record launcher
performs the bounded compile step before arming the final VM.

For an existing distributed release:

```sh
beamtrace capture my_app@host \
  --trigger Elixir.MyApp.Worker:run/1 \
  --cookie-file /run/secrets/beam.cookie
```

Never place the cookie value itself on the command line.
