<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Upstream candidate gate

This file records why BeamTrace keeps reviewed fork pins without opening an
upstream issue or pull request. It is an evidence ledger, not an assertion that
either upstream has a defect. Any movement of an upstream branch invalidates
the corresponding SHA observations below and requires the complete gate to be
run again.

No external issue, pull request, comment, or branch push was made during this
review.

## Review snapshot: 2026-08-24

### Lustre

- BeamTrace fork pin: `2d0b444a52bab6da8637c7f3a5f6c26399eb200f`.
- Observed `lustre-labs/lustre` `main`:
  `ff866bb0b456866f7452bc27d74564eed34afdba`.
- The fork change is not based on that observed main and includes unrelated
  workflow/release changes plus a test-only `unescapeKey` export. That diff is
  not an upstream candidate.
- A repository issue/PR search for hydration, virtualisation, keyed identity,
  entities, and unescaping found related keyed/virtualisation reports, including
  [PR 446](https://github.com/lustre-labs/lustre/pull/446) and
  [issue 450](https://github.com/lustre-labs/lustre/issues/450), but neither was
  an exact public reproduction of the entity-decoding identity case. This
  search must be repeated against the then-current repository before any
  proposal.
- At the observed main SHA, `parseKey` still performs a chain of entity
  replacements. That observation alone is not proof of incorrect public
  behavior.

The required public-boundary reproduction is still missing. It must render
keys through Lustre's server renderer, parse the resulting HTML comments,
virtualise the DOM, and complete the first reconciliation. It must cover
`&amp;#39;`, `&lt;`, quotes, Unicode, combining characters, emoji, the empty
key, and a bounded long key, with generated round-trip cases. Results must
agree in Chromium, Firefox, and WebKit and be justified against the
[WHATWG HTML comment-tokenization rules](https://html.spec.whatwg.org/multipage/parsing.html).

Exploitability has not been established and this is not classified as a
security vulnerability. Because the end-to-end/browser evidence and security
assessment are incomplete, no public question, issue, or PR may be created.
If the full gate becomes green, the candidate must contain only a single-pass
decode and its end-to-end regression test, following
[Lustre support guidance](https://github.com/lustre-labs/lustre#support).

### etui

- BeamTrace fork pin: `99886c6a280281c6a4b80d0d354e979eb60590e5`.
- Observed `lupodevelop/etui` `main`:
  `699d2c0a1e7f5d2ae109b00927bd5484a056517a`.
- The fork commit is directly based on that observed main, but it changes CI,
  `CONTRIBUTING.md`, and `CHANGELOG.md` as well as terminal behavior. Those
  repository-policy and release-note changes are excluded from any upstream
  candidate.
- Upstream's observed contribution contract says OTP 26+, while the fork
  changes it to OTP 27+. The raw/cooked `noshell` mode is documented as an
  OTP 28 addition in the
  [OTP 28 stdlib release notes](https://www.erlang.org/docs/28/apps/stdlib/notes.html).
  A POSIX-only fallback cannot silently narrow upstream's Windows or OTP 26
  support.
- A repository issue/PR search for OTP 27, raw/cooked mode, single-key input,
  and `noshell` returned no exact duplicate at this snapshot. That negative
  search is not permanent evidence and must be repeated.

The required controlling-terminal matrix is not available: OTP 26/27/28/29 on
Linux, macOS, and Windows PTY/ConPTY must cover a single key, arrows and escape
sequences, Ctrl+C, CJK, combining characters, emoji, paste, resize, normal
exit, crash, and terminal restoration. BeamTrace currently exercises its
pinned fork on its own supported OTP range; this does not prove etui's full
upstream support matrix.

Until the full matrix has one correct implementation, the only possible
upstream artifact is a maintainer question about the desired support boundary.
Even that question must be shown to and approved by the user first. No upstream
submission is currently authorized.

## Pin policy

Both fork SHAs remain immutable BeamTrace dependencies. They may return to Hex
only after an upstream fix is merged, a formal release containing it is
published, and BeamTrace's complete OS/OTP/browser/PTY consumer matrix passes.
If either candidate remains unproven, retaining the pin and this explicit
record is the correct outcome.
