#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
transcript="$(mktemp)"
cleanup() {
  rm -f -- "$transcript"
}
trap cleanup EXIT

cd "$repo_root/packages/beamtrace_tui"
printf 'q' | timeout 30s script --quiet --return --command 'gleam run' "$transcript"

LC_ALL=C grep -a -q 'BeamTrace' "$transcript"
LC_ALL=C grep -a -q 'q quit' "$transcript"
