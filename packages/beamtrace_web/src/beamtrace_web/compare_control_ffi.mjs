// SPDX-License-Identifier: Apache-2.0 OR MIT

import { apiError } from "./api_error_ffi.mjs";

export function requestCompare(body, onSuccess, onError) {
  fetch("/api/v2/compare", {
    method: "POST",
    credentials: "same-origin",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
    },
    body,
  })
    .then(async (response) => {
      const payload = await response.text();
      if (!response.ok) {
        throw new Error(apiError(payload, response.status, "compare request failed"));
      }
      return payload;
    })
    .then(onSuccess)
    .catch((error) => {
      onError(error instanceof Error ? error.message : "compare request failed");
    });
}
