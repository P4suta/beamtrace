<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# CLI reference

The executable generates every command's help, defaults, examples, shell
completion, and error catalogue from one declarative specification; it is the
exact reference:

```sh
beamtrace help
beamtrace help COMMAND
beamtrace COMMAND --help
beamtrace help errors
beamtrace completion bash|zsh|fish|powershell
```

## Commands

| Command | Summary |
|---|---|
| `help` | Show the command guide or detailed help for one command. |
| `attach` | Attach an interactive workspace to an existing BEAM node. |
| `capture` | Capture one bounded causal operation from an existing node. |
| `record` | Launch a Gleam, Mix, Rebar3 or Erlang command and record one MFA. |
| `open` | Open a trace in the Web workspace or TUI. |
| `compare` | Compare 2 to 20 trace archives. |
| `export` | Export a trace without changing its evidence semantics. |
| `validate` | Verify container safety, canonical JSON, checksums and the causal graph. |
| `migrate` | Migrate a v1 archive to v2 without modifying the source. |
| `serve` | Serve a local or configured Team workspace. |
| `demo` | Record the bundled fixture and show the result. |
| `relay` | Enroll and run an outbound Team relay. |
| `tui` | Open the canonical terminal client. |
| `init` | Create a safe project-local beamtrace.toml. |
| `config` | Validate project defaults and profiles. |
| `doctor` | Check runtime, assets, distribution and optional tools. |
| `mcp` | Run the stdio MCP server. |
| `completion` | Generate shell completion from this command specification. |
| `version` | Print the BeamTrace version. |

No arguments prints a short guide. `--help` or `-h` is accepted anywhere before
`--`. An unknown command or option names the nearest candidate; a value-taking
option without a value is reported as such. Local Web ports default to `0`, and
the browser opens only from an interactive terminal unless `--no-open` is used.
`record` and `capture` accept `--capture-window SECONDS` (default 30, at most
300) for the bounded wait after arming.

## JSON result envelope

Finite commands accept `--json` and emit one stdout object described by
[`schemas/beamtrace-cli-v1/envelope.schema.json`](../schemas/beamtrace-cli-v1/envelope.schema.json):

```json
{"schema_version":1,"command":"version","ok":true,"exit_code":0,"artifact":{"version":"<version>"},"outcome":null,"error":null}
```

`command` is one of the specified command names, `config check`, or `unknown`.
`ok` is true exactly when `error` is null; `exit_code` still carries the outcome
(1 for a comparison difference or application exit status, 3 for a capture
integrity issue). Artifacts that name a file carry both `path` and
`absolute_path`. `doctor` adds `checks`, one `{ok, hint?}` object per check.
Errors carry `code`, `message`, `hint`, and an optional `detail` tail.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | comparison difference or application exit status |
| 2 | usage, connection, configuration, or storage failure |
| 3 | capture integrity issue |
| 4 | safety refusal |
| 130 | record interrupted by SIGINT |
| 143 | record terminated by SIGTERM |

## Error codes

Human output prints `beamtrace[LABEL]: message` followed by `Next: hint`; the
JSON `error.code` is the lower-case label. `beamtrace help errors` prints the
same table.

| Label | `error.code` | Exit |
|---|---|---|
| `E_AGENT_BEAM_UNAVAILABLE` | `agent_beam_unavailable` | 2 |
| `E_ARCHIVE_NOT_FOUND` | `archive_not_found` | 2 |
| `E_CAPTURE_ARM_TIMEOUT` | `capture_arm_timeout` | 2 |
| `E_CAPTURE_FAILED` | `capture_failed` | 2 |
| `E_CAPTURE_INCOMPLETE` | `capture_incomplete` | 2 |
| `E_CAPTURE_INTEGRITY` | `capture_integrity` | 3 |
| `E_CHECKSUM_MISMATCH` | `checksum_mismatch` | 2 |
| `E_CHILD_CRASHED` | `child_crashed` | 2 |
| `E_CHILD_START_FAILED` | `child_start_failed` | 2 |
| `E_COMMAND_FAILED` | `command_failed` | 2 |
| `E_COMMAND_NOT_FOUND` | `command_not_found` | 2 |
| `E_DUPLICATE_ENTRY` | `duplicate_entry` | 2 |
| `E_INVALID_ARGUMENTS` | `invalid_arguments` | 2 |
| `E_INVALID_CONTAINER` | `invalid_container` | 2 |
| `E_INVALID_GRAPH` | `invalid_graph` | 2 |
| `E_INVALID_SEARCH` | `invalid_search` | 2 |
| `E_INVALID_WINDOW` | `invalid_window` | 2 |
| `E_IO_ERROR` | `io_error` | 2 |
| `E_MIGRATION_OUTPUT_CONFLICT` | `migration_output_conflict` | 2 |
| `E_OPERATION_OUTCOME` | `operation_outcome` | 1 |
| `E_OUTPUT_EXISTS` | `output_exists` | 2 |
| `E_SAFETY_REFUSAL` | `safety_refusal` | 4 |
| `E_SCHEMA_ERROR` | `schema_error` | 2 |
| `E_SYSTEM_TRACER_OCCUPIED` | `system_tracer_occupied` | 4 |
| `E_TARGET_UNAVAILABLE` | `target_unavailable` | 2 |
| `E_TARGET_UNREACHABLE` | `target_unreachable` | 2 |
| `E_TRIGGER_TIMEOUT` | `trigger_timeout` | 2 |
| `E_UNSAFE_ENTRY` | `unsafe_entry` | 2 |
| `E_WEB_ASSETS_UNAVAILABLE` | `web_assets_unavailable` | 2 |
| `E_ZIP_BOMB` | `zip_bomb` | 2 |
