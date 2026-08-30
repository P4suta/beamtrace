// SPDX-License-Identifier: Apache-2.0 OR MIT

import { apiError } from "./api_error_ffi.mjs";

let captureActive = false;
let mfaSearchTimer;
let mfaSearchController;

async function request(path, options = {}) {
  const response = await fetch(path, {
    credentials: "same-origin",
    headers: {
      accept: "application/json",
      ...(options.body ? { "content-type": "application/json" } : {}),
    },
    ...options,
  });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(apiError(body, response.status, "capture request failed"));
  }
  return body;
}

function complete(promise, onSuccess, onError) {
  promise.then(onSuccess).catch((error) => {
    onError(error instanceof Error ? error.message : "capture request failed");
  });
}

export function armCapture(
  trigger,
  whereAql,
  preset,
  maxRoots,
  onSuccess,
  onError,
) {
  complete(
    request("/api/v2/sessions/current/arm", {
      method: "POST",
      body: JSON.stringify({
        trigger: trigger.trim(),
        where: whereAql.trim() || null,
        capture_window_ms: 30_000,
        drain_timeout_ms: 10_000,
        max_events: 100_000,
        max_bytes: 64_000_000,
        max_agent_mailbox: 10_000,
        max_roots: Number.parseInt(maxRoots, 10),
        preset,
      }),
    }).then((body) => {
      captureActive = true;
      return body;
    }),
    onSuccess,
    onError,
  );
}

export function fetchCaptureStatus(onSuccess, onError) {
  complete(
    request("/api/v2/sessions/current", { method: "GET" }).then((body) => {
      try {
        const status = JSON.parse(body).status;
        if (status === "ready" || status === "sealed" || status === "failed" || status === "idle") {
          captureActive = false;
        }
      } catch {
        // Gleam performs the authoritative decoding.
      }
      return body;
    }),
    onSuccess,
    onError,
  );
}

export function searchMfas(query, onSuccess, onError) {
  globalThis.clearTimeout(mfaSearchTimer);
  mfaSearchController?.abort();
  const normalized = query.trim();
  if (!normalized) {
    onSuccess('{"candidates":[]}');
    return;
  }
  mfaSearchTimer = globalThis.setTimeout(() => {
    mfaSearchController = new AbortController();
    request(
      `/api/v2/targets/current/mfas?q=${encodeURIComponent(normalized)}&limit=20`,
      { method: "GET", signal: mfaSearchController.signal },
    )
      .then(onSuccess)
      .catch((error) => {
        if (error?.name !== "AbortError") {
          onError(error instanceof Error ? error.message : "MFA search failed");
        }
      });
  }, 120);
}

export function cancelCapture(onSuccess, onError) {
  complete(
    request("/api/v2/sessions/current/cancel", { method: "POST" }),
    onSuccess,
    onError,
  );
}

export function saveCapture(path, onSuccess, onError) {
  complete(
    request("/api/v2/sessions/current/save", {
      method: "POST",
      body: JSON.stringify({ path }),
    }),
    onSuccess,
    onError,
  );
}

export function schedule(delayMs, callback) {
  globalThis.setTimeout(callback, Math.max(0, delayMs));
}

export function installPageCleanup() {
  globalThis.addEventListener("pagehide", () => {
    if (!captureActive) return;
    captureActive = false;
    fetch("/api/v2/sessions/current/cancel", {
      method: "POST",
      credentials: "same-origin",
      keepalive: true,
      headers: { accept: "application/json" },
    }).catch(() => {});
  });
}
