<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# AQL reference

AQL is the query language behind `--where` on `capture`, `record`, and
`relay`, the `where` key in `beamtrace.toml`, and the Advanced filter in the
Web workspace. A `--where` predicate selects which root operations are
captured; everything else about an accepted root is still recorded.
`beamtrace help aql` prints a summary of this page.

## Grammar

```text
expr       := comparison
            | expr "and" expr        # binds tighter than or
            | expr "or" expr         # binds loosest
            | "not" expr             # binds tightest
            | "(" expr ")"
comparison := field operator value
operator   := "==" | "!=" | ">" | ">=" | "<" | "<="
```

## Values

| Literal | Examples | Notes |
|---|---|---|
| String | `"charge"`, `checkout` | Double-quoted, or a bare word (also compared as a string). |
| Integer / float | `3`, `1.5` | |
| Boolean | `true`, `false` | |
| Duration | `250ns`, `10us`, `250ms`, `2s` | Suffixes ns/us/ms/s, normalised to milliseconds; the number part must be an integer. |

## Fields

The capture event vocabulary is defined by `aql.event_fields()` in
`beamtrace_core` — the CLI help and this table render from the same list.
`*` stands for one zero-based argument index (`arg.0.tag`, `arg.7.size`).

| Field | Type | Meaning |
|---|---|---|
| `node` | string | Observing node. |
| `process.pid` | string | Observing process PID. |
| `root_id` | string | Root operation identifier. |
| `event.kind` | string | Event kind name (`root`, `send`, `receive`, …). |
| `exact` | bool | Whether the event's evidence is exact. |
| `timestamp_ns` | int | Node-relative offset in nanoseconds. |
| `process.label` | string | Logical actor label, when resolved. |
| `process.logical_id` | string | Logical actor id, when resolved. |
| `process.registered_name` | string | Registered name evidence. |
| `process.initial_call` | string | Initial call MFA evidence. |
| `process.ancestor` | string | Ancestor evidence. |
| `process.child_id` | string | Supervisor child id evidence. |
| `process.restart_proximity_ms` | int | Restart proximity evidence. |
| `mfa` | string | Trigger `Module:function/arity` (root events). |
| `module` | string | Trigger module (root events). |
| `function` | string | Trigger function (root events). |
| `arity` | int | Trigger arity (root events). |
| `arg.count` | int | Root argument count. |
| `arg.*.tag` | string | Tag of one root argument. |
| `arg.*.size` | int | Bounded size of one root argument. |
| `arg.*.type` | string | Shape of one root argument (`atom`, `tuple`, `list`, `map`, …). |
| `message.tag` | string | Tag of a sent/received message. |
| `message.size` | int | Bounded size of a sent/received message. |
| `message.type` | string | Shape of a sent/received message. |

## Evaluation rules

- A missing field, or a comparison across different types, evaluates to
  `false` — never to an error.
- Field names are validated when the query is parsed: a typo fails
  immediately with a caret report and a did-you-mean suggestion instead of
  silently matching nothing.
- The dependency-free target agent evaluates only the argument-shape subset
  (`arg.*.tag`, `arg.*.type` with `==`/`!=`); the rest of the query is
  evaluated as a residual after collection. Mixed `or`/`not` expressions
  stay wholly residual so no valid root is discarded early.

## Examples

```text
beamtrace record --trigger shop:checkout/1 \
  --where 'arg.0.tag == "order" and exact == true' -- gleam run

beamtrace capture app@host --trigger shop:checkout/1 \
  --where 'message.size > 4096 or not process.label == "checkout"'

# beamtrace.toml
[profiles.slow]
trigger = "shop:checkout/1"
where = "timestamp_ns > 250000000 and arg.0.type == tuple"
```
