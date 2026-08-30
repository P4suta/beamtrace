// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/workspace

/// Apply the user-selected theme without persisting it or contacting any
/// external service. System mode continues to follow the OS media query.
pub fn apply(theme: workspace.Theme) -> Nil {
  set_theme(case theme {
    workspace.SystemTheme -> "system"
    workspace.LightTheme -> "light"
    workspace.DarkTheme -> "dark"
  })
}

/// Return the platform's conventional command modifier for visible shortcut
/// labels. Keyboard handling accepts both Control and Command.
pub fn modifier_label() -> String {
  platform_modifier()
}

@external(javascript, "./appearance_ffi.mjs", "setTheme")
fn set_theme(theme: String) -> Nil

@external(javascript, "./appearance_ffi.mjs", "platformModifier")
fn platform_modifier() -> String
