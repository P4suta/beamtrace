<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0012 — AQL errors are typed, caret-rendered, and field-checked

Status: Accepted · 2026-09-01

## Context

`aql.AqlError` was a free-form `(offset, message)` pair — the only core error type without a renderer (ADR 0006) — and typos in `--where` fields were silently evaluated to false because no vocabulary existed to check them against.

## Decision

- `AqlError` becomes ten typed variants that all carry `offset: Int` first, so `error.offset` keeps working. `aql.error_message` is the one-line renderer required by ADR 0006.
- ADR 0006 is amended: an error type whose variants carry source offsets may additionally expose one source-context reporter. `aql.error_report(source:, error:)` renders the query with a grapheme-aligned caret; the field catalogue stays out of the report and is composed by callers from `event_fields`.
- `aql.event_fields()` is the single vocabulary of capture-event fields (`arg.*.…` patterns match one integer segment). The runtime's `event_context` must stay in sync with it — a runtime regression test enforces this.
- `aql.parse_for(source, fields:)` validates field names during parsing, where offsets are still known, and suggests the nearest catalogued field within edit distance two (wildcard segments substituted from the input; ties resolve alphabetically). `aql.parse` stays permissive for callers that evaluate arbitrary contexts.
- The CLI (`--where`), `capture.prepare`, and `beamtrace.toml` `where` values all use `parse_for` with `event_fields`, so a typo fails at parse time with the same message on every path.

## Consequences

Field typos that used to arm a capture that could never match are now rejected before arming. Error strings changed shape (`invalid AQL: …` with offsets inside the message); the CLI error catalogue is unaffected because these remain usage errors.
