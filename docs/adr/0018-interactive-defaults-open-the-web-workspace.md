<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0018 — Interactive defaults open the Web workspace

Status: Accepted · 2026-09-01

## Context

`record`, `open`, and `demo` default to the Web workspace on an interactive terminal, but `compare` alone defaulted to terminal text, so the same "no flags" habit produced a different experience on the one command where the visual workspace helps most. Scripts and CI, however, depend on the classic two-path terminal output and its difference exit code.

## Decision

- The principle: on an interactive terminal every viewer command defaults to the Web workspace; a non-interactive invocation keeps its scriptable output. `compare` now follows it via a `CompareAuto` display resolved by the pure `cli.resolve_compare_display(display, interactive:)`.
- The 2-path `Compare` command variant is deleted; `CompareMany` with `CompareAuto` is the single parse result for mode-less invocations. A resolved terminal display on exactly two archives still runs the classic pairwise comparison, so non-interactive stdout and exit codes (difference = 1) are byte-compatible.
- Explicit `--web`, `--tui`, `--no-open`, and `--json` behave as before; `--port` continues to imply the Web workspace.

## Consequences

Interactive `beamtrace compare a b` opens the workspace like every other viewer. Pipes, CI, and `--json` are unchanged. The spec's defaults lines document both halves and render into help and completion automatically.
