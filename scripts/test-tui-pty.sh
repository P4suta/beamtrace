#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d)"
transcript="$temp_dir/transcript"
input="$temp_dir/input"
output="$temp_dir/output"
cleanup() {
  rm -f -- "$transcript" "$input" "$output"
  rmdir -- "$temp_dir"
}
trap cleanup EXIT

mkfifo "$input"
cd "$repo_root/packages/beamtrace_tui"
timeout 30s script --quiet --return --command 'gleam run' "$transcript" <"$input" \
  | tee "$output" &
script_pid=$!
exec 3>"$input"

ready=false
for _ in $(seq 1 300); do
  if LC_ALL=C grep -a -q 'q quit' "$output" 2>/dev/null; then
    ready=true
    break
  fi
  if ! kill -0 "$script_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if [[ "$ready" != true ]]; then
  exec 3>&-
  wait "$script_pid" || true
  echo 'TUI did not become ready within 30 seconds.' >&2
  exit 1
fi

printf 'q' >&3
exec 3>&-
if ! wait "$script_pid"; then
  echo 'TUI did not exit cleanly after the quit key.' >&2
  exit 1
fi

LC_ALL=C grep -a -q 'BeamTrace' "$transcript"
LC_ALL=C grep -a -q 'q quit' "$transcript"
