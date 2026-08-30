# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'invoke-gleam-with-network-retry.ps1')
& (Join-Path $PSScriptRoot 'ensure-rebar3.ps1')
$env:PATH = "$PSScriptRoot;$env:PATH"
$env:REBAR_CACHE_DIR = Join-Path $repoRoot '.cache\rebar3'

Push-Location (Join-Path $repoRoot 'packages\beamtrace_web')
try {
    $build = Invoke-GleamWithNetworkRetry -Arguments @('run', '-m', 'lustre/dev', 'build')
    if (-not [string]::IsNullOrWhiteSpace($build.Output)) {
        Write-Host $build.Output.TrimEnd()
    }
    if ($build.ExitCode -ne 0) { exit $build.ExitCode }
    Copy-Item -LiteralPath 'assets/index.html' -Destination 'dist/index.html' -Force
    Copy-Item -LiteralPath 'assets/styles.css' -Destination 'dist/styles.css' -Force
    exit 0
}
finally {
    Pop-Location
}
