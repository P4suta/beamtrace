// SPDX-License-Identifier: Apache-2.0 OR MIT

export function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
}

export function platformModifier() {
  const platform = navigator.userAgentData?.platform || navigator.platform || "";
  return /Mac|iPhone|iPad|iPod/i.test(platform) ? "⌘" : "Ctrl";
}
