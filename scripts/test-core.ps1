# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'ensure-rebar3.ps1')
$env:PATH = "$PSScriptRoot;$env:PATH"
$env:REBAR_CACHE_DIR = Join-Path $repoRoot '.cache\rebar3'

Push-Location (Join-Path $repoRoot 'packages\beamtrace_core')
try {
    & gleam test
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & gleam test --target javascript
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
}

& node (Join-Path $PSScriptRoot 'check-core-docs.mjs')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& (Join-Path $PSScriptRoot 'test-core-interface.ps1')
exit $LASTEXITCODE
