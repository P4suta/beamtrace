# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'invoke-gleam-with-network-retry.ps1')

& (Join-Path $PSScriptRoot 'ensure-rebar3.ps1')
$env:PATH = "$PSScriptRoot;$env:PATH"
$env:REBAR_CACHE_DIR = Join-Path $repoRoot '.cache\rebar3'

Push-Location (Join-Path $repoRoot 'fixtures\gleam')
try {
    $download = Invoke-GleamWithNetworkRetry -Arguments @('deps', 'download')
    if (-not [string]::IsNullOrWhiteSpace($download.Output)) {
        Write-Host $download.Output.TrimEnd()
    }
    if ($download.ExitCode -ne 0) { exit $download.ExitCode }
    & gleam test
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally { Pop-Location }

Push-Location (Join-Path $repoRoot 'fixtures\erlang')
try {
    & (Join-Path $PSScriptRoot 'rebar3.ps1') eunit
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally { Pop-Location }

$mix = Get-Command mix -ErrorAction SilentlyContinue
if ($null -ne $mix) {
    Push-Location (Join-Path $repoRoot 'fixtures\elixir')
    try {
        & mix test
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    finally { Pop-Location }
}
else {
    if ($env:BEAMTRACE_REQUIRE_ELIXIR -eq '1') {
        throw 'mix is required for this TDD gate but is not installed.'
    }
    Write-Warning 'mix is not installed; Elixir fixture tests were skipped locally.'
}

exit 0
