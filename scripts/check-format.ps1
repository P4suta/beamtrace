# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$paths = @(
    'packages/beamtrace_core/src',
    'packages/beamtrace_core/test',
    'packages/beamtrace_runtime/src',
    'packages/beamtrace_runtime/test',
    'packages/beamtrace_web/src',
    'packages/beamtrace_web/test',
    'packages/beamtrace_tui/src',
    'packages/beamtrace_tui/test',
    'fixtures/gleam/src',
    'fixtures/gleam/test'
) | ForEach-Object { Join-Path $repoRoot $_ }

& gleam format --check @paths
exit $LASTEXITCODE
