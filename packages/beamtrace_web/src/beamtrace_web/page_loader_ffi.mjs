// SPDX-License-Identifier: Apache-2.0 OR MIT

export function pageUrl(start, limit, search) {
  const query = new URLSearchParams({
    start: String(start),
    limit: String(limit),
  });
  if (search.trim() !== "") {
    query.set("q", search.trim());
  }
  return `/api/v2/sessions/current/events?${query}`;
}

export function fetchPage(start, limit, search, onSuccess, onError) {
  fetch(pageUrl(start, limit, search), {
    method: "GET",
    credentials: "same-origin",
    headers: { accept: "application/json" },
  })
    .then(async (response) => {
      const body = await response.text();
      if (!response.ok) {
        throw new Error(`event page request failed (${response.status})`);
      }
      return body;
    })
    .then(onSuccess)
    .catch((error) => {
      onError(error instanceof Error ? error.message : "event page request failed");
    });
}
