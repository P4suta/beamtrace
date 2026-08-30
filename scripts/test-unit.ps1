# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

foreach ($suite in @(
    @{ Path = 'packages/beamtrace_core'; Arguments = @('test') },
    @{ Path = 'packages/beamtrace_core'; Arguments = @('test', '--target', 'javascript') },
    @{ Path = 'packages/beamtrace_runtime'; Arguments = @('test', '--', '--unit') },
    @{ Path = 'packages/beamtrace_tui'; Arguments = @('test') },
    @{ Path = 'packages/beamtrace_web'; Arguments = @('test', '--target', 'javascript') }
)) {
    Push-Location (Join-Path $repoRoot $suite.Path)
    try {
        & gleam @($suite.Arguments)
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    finally { Pop-Location }
}

Push-Location $repoRoot
try {
    & npm run test:property
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally { Pop-Location }

& (Join-Path $PSScriptRoot 'test-core-interface.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& node (Join-Path $PSScriptRoot 'check-core-docs.mjs')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& node (Join-Path $PSScriptRoot 'generate-openapi-module.mjs') --check
exit $LASTEXITCODE
