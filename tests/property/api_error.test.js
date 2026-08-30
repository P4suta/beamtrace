// SPDX-License-Identifier: Apache-2.0 OR MIT
const assert = require("node:assert/strict");
const test = require("node:test");

test("Web API errors render the v2 code, message, hint without proxy bodies", async () => {
  const { apiError } = await import(
    "../../packages/beamtrace_web/src/beamtrace_web/api_error_ffi.mjs"
  );
  assert.equal(
    apiError(
      JSON.stringify({
        error: {
          code: "permission_denied",
          message: "This session does not have permission.",
          hint: "Request the required BeamTrace role.",
        },
      }),
      403,
      "team trace request failed",
    ),
    "This session does not have permission. Next: Request the required BeamTrace role. [permission_denied]",
  );
  assert.equal(apiError('{"error":"legacy_code"}', 400, "request failed"), "legacy_code");
  assert.equal(
    apiError("<html>sensitive proxy detail</html>", 502, "request failed"),
    "request failed (502)",
  );
});
