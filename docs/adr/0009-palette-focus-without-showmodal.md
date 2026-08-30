<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# 0009 — Keyboard focus is managed with effects, not `showModal()`

Status: Accepted · 2026-08-30

## Context

`4` was advertised but not forwarded, `/` set a flag nobody read, and the command palette was a `<dialog open>` that Escape could not close. Lustre (a pinned fork) renders the dialog through its virtual DOM; calling `showModal()` on that element conflicts with the `open` attribute the renderer patches.

## Decision

The DOM listener forwards `1`–`4`, `/`, Ctrl/Cmd+K, Escape, and traps Tab inside the palette. Focus moves through FFI effects scheduled on the next animation frame (`focusSearch`, `focusPalette`, `restoreFocus`), the first palette action carries `autofocus`, and the app update routes `UserPressedKey` through `keyboard_shortcut` so effects run. The dialog stays attribute-driven.

## Consequences

Every advertised shortcut works and is tested by key presses in Playwright; no fork change is needed.
