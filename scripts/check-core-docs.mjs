// SPDX-License-Identifier: Apache-2.0 OR MIT
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const interfacePath = `${root}/packages/beamtrace_core/test/package-interface-v0.4.json`;
const packageInterface = JSON.parse(readFileSync(interfacePath, "utf8"));
const missing = [];

for (const [moduleName, module] of Object.entries(packageInterface.modules)) {
  if (!module.documentation || module.documentation.length === 0) {
    missing.push(`${moduleName} (module)`);
  }
  for (const collection of ["types", "type-aliases", "functions", "constants"]) {
    for (const [name, item] of Object.entries(module[collection] ?? {})) {
      if (!item.documentation || item.documentation.length === 0) {
        missing.push(`${moduleName}.${name}`);
      }
    }
  }
}

if (missing.length > 0) {
  console.error(`Undocumented beamtrace_core public API:\n${missing.join("\n")}`);
  process.exitCode = 1;
} else {
  console.log("beamtrace_core public API documentation coverage passed.");
}
