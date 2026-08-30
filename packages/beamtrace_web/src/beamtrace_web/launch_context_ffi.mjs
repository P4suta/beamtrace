// SPDX-License-Identifier: Apache-2.0 OR MIT

export function consumeComparePaths() {
  const url = new URL(window.location.href);
  const value = url.searchParams.get("compare") || "";
  if (url.searchParams.has("compare")) {
    url.searchParams.delete("compare");
    const clean = `${url.pathname}${url.search}${url.hash}`;
    window.history.replaceState(null, "", clean);
  }
  return value;
}
