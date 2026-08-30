// SPDX-License-Identifier: Apache-2.0 OR MIT

import { apiError } from "./api_error_ffi.mjs";

function request(path, options = {}) {
  const { headers = {}, ...requestOptions } = options;
  return fetch(path, {
    credentials: "same-origin",
    ...requestOptions,
    headers: { accept: "application/json", ...headers },
  }).then(async (response) => {
    const body = await response.text();
    if (!response.ok) {
      throw new Error(apiError(body, response.status, "team trace request failed"));
    }
    return body;
  });
}

function complete(promise, onSuccess, onError) {
  promise.then(onSuccess).catch((error) => {
    onError(error instanceof Error ? error.message : "team trace request failed");
  });
}

function cursorQuery(cursor, limit) {
  const query = new URLSearchParams({ limit: String(limit) });
  if (cursor) query.set("cursor", cursor);
  return query.toString();
}

export function fetchTraces(cursor, onSuccess, onError) {
  complete(
    request(`/api/v2/traces?${cursorQuery(cursor, 50)}`),
    onSuccess,
    onError,
  );
}

export function fetchEvents(traceId, cursor, onSuccess, onError) {
  complete(
    request(
      `/api/v2/traces/${encodeURIComponent(traceId)}/events?${cursorQuery(cursor, 200)}`,
    ),
    onSuccess,
    onError,
  );
}

function cookie(name) {
  const prefix = `${name}=`;
  for (const part of document.cookie.split(";")) {
    const value = part.trim();
    if (value.startsWith(prefix)) return decodeURIComponent(value.slice(prefix.length));
  }
  return "";
}

export function updateHold(traceId, enabled, onSuccess, onError) {
  const csrf = cookie("beamtrace_csrf");
  complete(
    request(`/api/v2/traces/${encodeURIComponent(traceId)}/hold`, {
      method: enabled ? "POST" : "DELETE",
      headers: { "x-beamtrace-csrf": csrf },
    }),
    onSuccess,
    onError,
  );
}
