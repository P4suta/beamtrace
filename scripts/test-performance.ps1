# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $IsLinux) {
    Write-Host 'Performance gate is Linux-only; skipped on this platform.'
    exit 0
}

Push-Location (Join-Path $repoRoot 'packages/beamtrace_core')
try {
    & gleam build --target erlang
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
}

Push-Location (Join-Path $repoRoot 'packages/beamtrace_runtime')
try {
    & gleam build --target erlang
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
}

& escript (Join-Path $PSScriptRoot 'performance-gate.escript') $repoRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& escript (Join-Path $PSScriptRoot 'runtime-performance-gate.escript') $repoRoot
exit $LASTEXITCODE
