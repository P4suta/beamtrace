<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# CLI reference

The executable generates all command help, defaults, examples, and shell
completion from one declarative specification. Use the executable as the exact
reference:

```sh
beamtrace help
beamtrace help COMMAND
beamtrace COMMAND --help
beamtrace completion bash
beamtrace completion zsh
beamtrace completion fish
beamtrace completion powershell
```

Primary commands are `demo`, `record`, `capture`, `attach`, `open`, `compare`,
`export`, `validate`, `migrate`, `serve`, `relay`, `tui`, `init`, `config check`,
`doctor`, and `mcp`.

No arguments prints a short successful guide. Unknown commands include a near
candidate and corrected help invocation. Local Web ports default to `0` and
the browser is opened only from an interactive terminal unless `--no-open` is
used.

Finite commands support a single JSON stdout object:

```json
{"schema_version":1,"command":"version","ok":true,"exit_code":0,"artifact":{"version":"<version>"},"outcome":null,"error":null}
```

Errors contain stable `code`, `message`, and `hint` fields. Exit codes are 0
success, 1 comparison/application outcome, 2 usage/connect/configuration, 3
capture integrity, and 4 permission or safety refusal.
