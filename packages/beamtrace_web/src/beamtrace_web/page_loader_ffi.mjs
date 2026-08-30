// SPDX-License-Identifier: Apache-2.0 OR MIT

import { apiError } from "./api_error_ffi.mjs";

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
        throw new Error(apiError(body, response.status, "event page request failed"));
      }
      return body;
    })
    .then(onSuccess)
    .catch((error) => {
      onError(error instanceof Error ? error.message : "event page request failed");
    });
}
