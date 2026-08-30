// SPDX-License-Identifier: Apache-2.0 OR MIT

import { apiError } from "./api_error_ffi.mjs";

export function fetchLive(onSuccess, onError) {
  fetch("/api/v2/live?limit=200", {
    method: "GET",
    credentials: "same-origin",
    headers: { accept: "application/json" },
  })
    .then(async (response) => {
      const body = await response.text();
      if (!response.ok) {
        throw new Error(apiError(body, response.status, "live request failed"));
      }
      return body;
    })
    .then(onSuccess)
    .catch((error) => {
      onError(error instanceof Error ? error.message : "live request failed");
    });
}

export function schedule(delayMs, callback) {
  globalThis.setTimeout(callback, Math.max(0, delayMs));
}
