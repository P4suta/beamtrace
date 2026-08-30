#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

(cd "$repo_root/packages/beamtrace_core" && gleam test && gleam test --target javascript)
(cd "$repo_root/packages/beamtrace_runtime" && gleam test -- --unit)
(cd "$repo_root/packages/beamtrace_tui" && gleam test)
(cd "$repo_root/packages/beamtrace_web" && gleam test --target javascript)
(cd "$repo_root" && npm run test:property)

interface_file="$(mktemp "${TMPDIR:-/tmp}/beamtrace-core-interface.XXXXXX.json")"
trap 'rm -f "$interface_file"' EXIT
(cd "$repo_root/packages/beamtrace_core" && gleam export package-interface --out "$interface_file")
if ! cmp -s "$repo_root/packages/beamtrace_core/test/package-interface-v0.3.json" "$interface_file"; then
  echo "beamtrace_core public API differs from test/package-interface-v0.3.json" >&2
  exit 1
fi

node "$repo_root/scripts/check-core-docs.mjs"
node "$repo_root/scripts/generate-openapi-module.mjs" --check

echo "Unit suites and the v0.3 package interface passed."
