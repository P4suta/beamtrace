# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'ensure-rebar3.ps1')
$env:PATH = "$PSScriptRoot;$env:PATH"
$env:REBAR_CACHE_DIR = Join-Path $repoRoot '.cache\rebar3'

Push-Location (Join-Path $repoRoot 'packages\beamtrace_web')
try {
    & gleam run -m lustre/dev build
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Copy-Item -LiteralPath 'assets/index.html' -Destination 'dist/index.html' -Force
    Copy-Item -LiteralPath 'assets/styles.css' -Destination 'dist/styles.css' -Force
    exit 0
}
finally {
    Pop-Location
}
