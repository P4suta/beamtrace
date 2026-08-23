# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'enable-msvc.ps1')
& (Join-Path $PSScriptRoot 'ensure-rebar3.ps1')
$env:PATH = "$PSScriptRoot;$env:PATH"
$env:REBAR_CACHE_DIR = Join-Path $repoRoot '.cache\rebar3'

Push-Location (Join-Path $repoRoot 'packages\beamtrace_runtime')
try {
    & gleam test
    $gleamExit = $LASTEXITCODE
}
finally {
    Pop-Location
}

if ($gleamExit -ne 0) {
    exit $gleamExit
}
exit 0
