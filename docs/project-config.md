<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Project configuration (beamtrace.toml)

`beamtrace.toml` supplies defaults and named profiles for `capture` and
`record`, so a team can run `beamtrace record --profile local` instead of
repeating flags. Create it with `beamtrace init` and verify it with
`beamtrace config check`, which prints the file that is in effect.

## Discovery

BeamTrace looks for `beamtrace.toml` starting in the working directory and
walking toward the filesystem root, stopping at the first match, at a
repository boundary (a directory containing `.git`, whether a directory or a
worktree file), or at the root. Configuration outside the repository is never
picked up, so a subdirectory of your project uses the project file while a
run outside any repository only sees the current directory. The nearest file
wins. `beamtrace init` always writes to the current directory. Symlinked
configuration files are rejected.

## Format

```toml
[defaults]            # applied to every capture/record
max_roots = 1
preset = "generic"

[profiles.local]      # selected with --profile local
trigger = "my_app:main/0"
out = "traces/local.beamtrace"
```

Values are applied in order: `[defaults]`, then the selected profile, then
explicit command-line flags — the command line always wins.

## Keys

| Key | Maps to | Accepted values |
|---|---|---|
| `node` | `--node` | Non-empty string (also the positional `<node>` of `capture`). |
| `trigger` | `--trigger` | `Module:function/arity`; invalid MFAs are reported with the parser's message. |
| `where` | `--where` | An AQL root predicate; validated against the capture field vocabulary at load time, with offsets and did-you-mean suggestions on typos. |
| `out` | `--out` | A path, resolved relative to the configuration file's directory. |
| `cookie_file` | `--cookie-file` | A path, resolved like `out`; also audited by `beamtrace doctor`. |
| `max_roots` | `--max-roots` | Integer 1–1000. |
| `preset` | `--preset` | `generic`, `gleam-actor`, `wisp-mist`, `gen-server`, `phoenix`, `erlang-supervisor`. |

All string values are bounded; unknown keys are rejected with their full
path.

## Forbidden keys

Any key containing `command`, `cookie`, `grant`, `oidc`, `s3`, `secret`, or
`token` (anywhere in the file, case-insensitive) fails validation —
credentials and commands never belong in shared project configuration. The
single exception is `cookie_file`, which stores a path to a private file
rather than a secret value.

## Relationship to `--profile`

`--profile NAME` requires a discoverable `beamtrace.toml` and selects
`[profiles.NAME]`. Without `--profile`, `[defaults]` still applies when the
file is found. `beamtrace config check` reports the discovered path and the
profile count; `beamtrace doctor` additionally audits every referenced
cookie file's permissions.
