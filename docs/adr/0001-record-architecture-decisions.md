<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0001 — Record architecture decisions

Status: Accepted · 2026-08-30

## Context

Design decisions were spread across commit bodies, prose docs, and review threads, so their reasoning was hard to find and easy to contradict.

## Decision

Record every non-trivial design decision as one file `docs/adr/NNNN-<slug>.md` in MADR form: title, `Status: Proposed | Accepted | Superseded by NNNN · date`, then `Context`, `Decision`, `Consequences`. Keep each record under 30 lines. `docs/adr/README.md` lists one line per record. The docs gate checks that every record is indexed.

## Consequences

Decisions are discoverable and reviewable in the pull request that implements them. Prose docs stay limited to user-facing contracts and corrections.
