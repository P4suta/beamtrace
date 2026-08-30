// SPDX-License-Identifier: Apache-2.0 OR MIT

import { apiError } from "./api_error_ffi.mjs";

export function fetchGraph(onSuccess, onError) {
  fetch("/api/v2/sessions/current/graph", {
    method: "GET",
    credentials: "same-origin",
    headers: { accept: "application/json" },
  })
    .then(async (response) => {
      const body = await response.text();
      if (!response.ok) {
        throw new Error(apiError(body, response.status, "graph request failed"));
      }
      onSuccess(body);
    })
    .catch((error) => onError(String(error?.message ?? error)));
}
