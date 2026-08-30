#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

missing=()
for tool in erl epmd; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done
if ! command -v rebar3 >/dev/null 2>&1 || ! rebar3 version >/dev/null 2>&1; then
  missing+=("rebar3")
fi
if ! command -v mix >/dev/null 2>&1 || ! mix --version >/dev/null 2>&1; then
  missing+=("mix")
fi

if ((${#missing[@]} > 0)); then
  echo "SKIP integration: missing optional prerequisites: ${missing[*]}"
  exit 0
fi

if ! erl -noshell -eval 'case gen_tcp:listen(0, [{ip,{127,0,0,1}}]) of {ok,S} -> gen_tcp:close(S), halt(0); _ -> halt(1) end.'; then
  echo "SKIP integration: this environment does not permit loopback sockets"
  exit 0
fi

if ! epmd -daemon || ! epmd -names >/dev/null 2>&1; then
  echo "SKIP integration: EPMD cannot start in this environment"
  exit 0
fi

(cd "$repo_root/packages/beamtrace_runtime" && gleam test -- --integration)
echo "Runtime socket, EPMD, Rebar3, and Mix integration suite passed."
