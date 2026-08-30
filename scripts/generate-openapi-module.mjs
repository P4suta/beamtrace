// SPDX-License-Identifier: Apache-2.0 OR MIT
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const sourcePath = `${root}/packages/beamtrace_runtime/priv/openapi-v2.json`;
const modulePath = `${root}/packages/beamtrace_runtime/src/beamtrace_runtime/openapi.gleam`;
const document = JSON.stringify(JSON.parse(readFileSync(sourcePath, "utf8")));
const generated = `//// The bundled OpenAPI 3.1 contract for API v2.
////
//// Generated from priv/openapi-v2.json by scripts/generate-openapi-module.mjs.

// SPDX-License-Identifier: Apache-2.0 OR MIT

/// The exact JSON served from \`/api/v2/openapi.json\`.
pub const document = ${JSON.stringify(document)}
`;

if (process.argv.includes("--check")) {
  if (readFileSync(modulePath, "utf8") !== generated) {
    console.error("openapi.gleam is stale; run node scripts/generate-openapi-module.mjs");
    process.exitCode = 1;
  }
} else {
  writeFileSync(modulePath, generated);
}
