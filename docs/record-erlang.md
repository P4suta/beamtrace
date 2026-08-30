<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Record Erlang

Record a Rebar3 command or a direct Erlang invocation:

```sh
beamtrace record --trigger orders_worker:run/1 -- rebar3 shell
beamtrace record --trigger demo:run/0 --no-ui -- erl -noshell -s demo run -s init stop
```

The direct Erlang VM is gated before application code runs. Rebar3 is compiled
only when the trigger module is absent. BeamTrace resolves the executable once,
launches without a shell, uses an ephemeral cookie, and cleans the temporary
node assets on success, failure, timeout, or termination.
