#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
web_root="$repo_root/packages/beamtrace_web"

(cd "$web_root" && gleam run -m lustre/dev build)
cp "$web_root/assets/index.html" "$web_root/dist/index.html"
cp "$web_root/assets/styles.css" "$web_root/dist/styles.css"

echo "Built packages/beamtrace_web/dist."
