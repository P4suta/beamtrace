// SPDX-License-Identifier: Apache-2.0 OR MIT

export function apiError(body, status, fallback) {
  try {
    const parsed = JSON.parse(body);
    if (
      parsed?.error &&
      typeof parsed.error === "object" &&
      typeof parsed.error.code === "string" &&
      typeof parsed.error.message === "string" &&
      typeof parsed.error.hint === "string"
    ) {
      return `${parsed.error.message} Next: ${parsed.error.hint} [${parsed.error.code}]`;
    }
    if (typeof parsed?.error === "string") return parsed.error;
  } catch {
    // A proxy may return a bounded non-JSON error page. Do not surface it.
  }
  return `${fallback} (${status})`;
}
