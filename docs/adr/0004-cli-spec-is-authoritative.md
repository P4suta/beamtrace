<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0004 — The declarative command specification is authoritative

Status: Accepted · 2026-08-30

## Context

`cli_spec` drove help, examples, and completion while `cli` parsed arguments with hand-written pattern matches. Nothing linked them: flags the parser accepted were missing from help and completion (`record --profile`, `relay --where`), `--help` only worked as the second token, a missing option value was reported as an unknown option, and a hand-maintained list decided which commands were "known".

## Decision

`cli_spec` is the only source for command names, flags, value placeholders, enumerated values, and positional choices. The parser is not rewritten; it consults the specification in its generic paths — `--help`/`-h` anywhere before `--`, a pre-check that value-taking options have a value, free ordering of positionals and flags for path-first commands, `known/1` for the fallback, and `suggest_option/2` for unknown flags — and keeps its safety semantics (seq_trace acknowledgement, `--cookie` refusal, `--` isolation) untouched. A round-trip test proves every spec flag is accepted and every unlisted flag is rejected for every command, and every help example parses.

## Consequences

Adding a flag means adding it to the specification and the parser; the test fails until both agree. Help, completion, suggestions, and value validation stay consistent by construction.
