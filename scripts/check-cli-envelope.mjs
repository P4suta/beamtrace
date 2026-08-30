// SPDX-License-Identifier: Apache-2.0 OR MIT
// Validate one `beamtrace --json` result object against the envelope schema
// without a schema library: required keys, enums, types, and constants.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const schema = JSON.parse(
  readFileSync(join(here, "..", "schemas", "beamtrace-cli-v1", "envelope.schema.json"), "utf8"),
);
const input = readFileSync(process.stdin.fd, "utf8").trim();
const lines = input.split("\n").filter((line) => line.trim() !== "");
if (lines.length !== 1) {
  console.error(`expected exactly one JSON line, found ${lines.length}`);
  process.exit(1);
}
const value = JSON.parse(lines[0]);
const failures = [];
for (const key of schema.required) {
  if (!(key in value)) failures.push(`missing key ${key}`);
}
for (const key of Object.keys(value)) {
  if (!(key in schema.properties)) failures.push(`unexpected key ${key}`);
}
const p = schema.properties;
if (value.schema_version !== p.schema_version.const) failures.push("schema_version must be 1");
if (!p.command.enum.includes(value.command)) failures.push(`command ${value.command} is not in the closed set`);
if (typeof value.ok !== "boolean") failures.push("ok must be boolean");
if (!p.exit_code.enum.includes(value.exit_code)) failures.push(`exit_code ${value.exit_code} is not enumerated`);
if (value.ok !== (value.error === null)) failures.push("ok must be true exactly when error is null");
for (const key of ["artifact", "outcome"]) {
  const item = value[key];
  if (!(item === null || (typeof item === "object" && !Array.isArray(item)))) failures.push(`${key} must be null or an object`);
}
if ("invoked" in value && typeof value.invoked !== "string") failures.push("invoked must be a string");
if (value.error !== null) {
  const error = p.error.oneOf[1];
  for (const key of error.required) if (!(key in value.error)) failures.push(`error.${key} missing`);
  for (const key of Object.keys(value.error)) if (!(key in error.properties)) failures.push(`error.${key} unexpected`);
  if (!error.properties.code.enum.includes(value.error.code)) failures.push(`error.code ${value.error.code} is not catalogued`);
  for (const key of ["message", "hint"]) {
    if (typeof value.error[key] !== "string" || value.error[key].length < 1) failures.push(`error.${key} must be a non-empty string`);
  }
  if ("detail" in value.error && typeof value.error.detail !== "string") failures.push("error.detail must be a string");
}
if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log(`envelope ok: ${value.command} exit ${value.exit_code}`);
