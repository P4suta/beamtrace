// SPDX-License-Identifier: Apache-2.0 OR MIT
// Keep docs/environment-variables.md and the sources in sync, both ways:
// every BEAMTRACE_* variable read by shipped code must be documented or
// covered by a declared internal prefix, and every documented variable must
// still exist in the sources.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const referencePath = join(root, "docs", "environment-variables.md");
const reference = readFileSync(referencePath, "utf8");

const sourceRoots = [
  "packages/beamtrace_core/src",
  "packages/beamtrace_runtime/src",
  "packages/beamtrace_tui/src",
  "packages/beamtrace_web/src",
  "agent/src",
  "packaging",
];
const sourceFiles = ["scripts/beamtrace.ps1"];
const extensions = new Set([
  ".gleam",
  ".erl",
  ".mjs",
  ".js",
  ".sh",
  ".ps1",
  "",
]);

function* walk(directory) {
  for (const entry of readdirSync(directory)) {
    const path = join(directory, entry);
    if (statSync(path).isDirectory()) {
      yield* walk(path);
    } else {
      yield path;
    }
  }
}

function extension(path) {
  const index = path.lastIndexOf(".");
  return index < 0 ? "" : path.slice(index);
}

const pattern = /BEAMTRACE_[A-Z0-9_]*[A-Z0-9]/g;
const sourceVariables = new Set();
const files = sourceFiles.map((file) => join(root, file));
for (const directory of sourceRoots) {
  for (const path of walk(join(root, directory))) {
    if (extensions.has(extension(path))) files.push(path);
  }
}
for (const path of files) {
  const content = readFileSync(path, "utf8");
  for (const match of content.matchAll(pattern)) {
    sourceVariables.add(match[0]);
  }
}

// Internal prefixes are declared in the reference as `BEAMTRACE_XXX_*` rows.
const internalPrefixes = [...reference.matchAll(/`(BEAMTRACE_[A-Z0-9_]+_)\*`/g)]
  .map((match) => match[1]);
const documented = new Set(
  [...reference.matchAll(/`(BEAMTRACE_[A-Z0-9_]*[A-Z0-9])`/g)]
    .map((match) => match[1]),
);

// A name equal to a prefix stem (for example `BEAMTRACE_PARENT` captured
// from the string-concatenation `"BEAMTRACE_PARENT_" <> name`) counts as
// covered by that prefix.
const internal = (name) =>
  internalPrefixes.some(
    (prefix) => name.startsWith(prefix) || `${name}_` === prefix,
  );

const prefixStem = (name) =>
  internalPrefixes.some((prefix) => `${name}_` === prefix);

const undocumented = [...sourceVariables]
  .filter((name) => !internal(name) && !documented.has(name))
  .sort();
// Exact documented rows go stale even under an internal prefix; only the
// wildcard rows themselves (their stems) are exempt.
const stale = [...documented]
  .filter((name) => !prefixStem(name) && !sourceVariables.has(name))
  .sort();

if (internalPrefixes.length === 0) {
  console.error(
    "docs/environment-variables.md declares no internal `BEAMTRACE_..._*` prefixes.",
  );
  process.exitCode = 1;
} else if (undocumented.length > 0 || stale.length > 0) {
  if (undocumented.length > 0) {
    console.error(
      `Variables read by the sources but missing from docs/environment-variables.md:\n${undocumented.join("\n")}`,
    );
  }
  if (stale.length > 0) {
    console.error(
      `Variables documented but no longer read by any source:\n${stale.join("\n")}`,
    );
  }
  process.exitCode = 1;
} else {
  console.log("Environment variable reference is in sync with the sources.");
}
