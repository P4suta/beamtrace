// SPDX-License-Identifier: Apache-2.0 OR MIT

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
        let reason = `compare request failed (${response.status})`;
        try {
          const parsed = JSON.parse(payload);
          if (typeof parsed.error === "string") reason = parsed.error;
        } catch {
          // Retain the bounded status message for non-JSON proxy responses.
        }
        throw new Error(reason);
      }
      return payload;
    })
    .then(onSuccess)
    .catch((error) => {
      onError(error instanceof Error ? error.message : "compare request failed");
    });
}
