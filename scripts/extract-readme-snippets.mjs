// SPDX-License-Identifier: Apache-2.0 OR MIT
// Extract every ```gleam fence from a markdown file into snippet_N.gleam
// files so a build gate can prove each one is a complete, compilable module.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [source, outDir] = process.argv.slice(2);
if (!source || !outDir) {
  console.error("usage: extract-readme-snippets.mjs <markdown> <out-dir>");
  process.exit(2);
}

const text = readFileSync(source, "utf8");
const fences = [...text.matchAll(/```gleam\n([\s\S]*?)```/g)];
mkdirSync(outDir, { recursive: true });
fences.forEach((fence, index) => {
  writeFileSync(join(outDir, `snippet_${index + 1}.gleam`), fence[1]);
});
console.log(`${fences.length} gleam snippet(s) extracted from ${source}`);
