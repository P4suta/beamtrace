<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0017 — Project configuration discovery stops at the repository boundary

Status: Accepted · 2026-09-01

## Context

`beamtrace.toml` was only read from the exact working directory, so `beamtrace record --profile local` failed from any subdirectory of the project — unlike every comparable tool (git, mise, cargo) whose configuration is found upward. A naive upward walk, however, could silently adopt configuration from outside the checkout (a home or temp directory), which matters because profiles influence what gets traced and where archives are written.

## Decision

- `load` walks from the working directory toward the filesystem root and stops at the first `beamtrace.toml`, at a repository boundary — a directory containing `.git` as a directory or a worktree file — or at the root. The nearest file wins; configuration above the repository is never adopted.
- `beamtrace init` keeps writing to the working directory: creation is an explicit local act.
- Relative `out`/`cookie_file` values keep resolving against the configuration file's own directory, so a discovered parent file behaves identically from every subdirectory.
- `config check` prints the discovered absolute path, making the effective file visible from anywhere.
- The shipped template now documents discovery and comments the example profile out, so a freshly created file is valid and `init` no longer plants a placeholder MFA that guarantees a trigger timeout.

## Consequences

Running from a subdirectory now behaves like running from the root. A repository nested inside another repository sees only its own configuration. The eunit suite covers the parent hit, both boundary forms, and nearest-wins ordering with real directory trees.
