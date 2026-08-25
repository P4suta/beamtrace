// SPDX-License-Identifier: Apache-2.0 OR MIT

export function fetchLive(onSuccess, onError) {
  fetch("/api/v2/live?limit=200", {
    method: "GET",
    credentials: "same-origin",
    headers: { accept: "application/json" },
  })
    .then(async (response) => {
      const body = await response.text();
      if (!response.ok) {
        let reason = `live request failed (${response.status})`;
        try {
          const parsed = JSON.parse(body);
          if (typeof parsed.error === "string") reason = parsed.error;
        } catch {
          // Keep the bounded HTTP status message for non-JSON proxy errors.
        }
        throw new Error(reason);
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
