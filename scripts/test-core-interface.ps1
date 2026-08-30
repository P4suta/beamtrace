# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$packageRoot = Join-Path $repoRoot 'packages/beamtrace_core'
$snapshot = Join-Path $packageRoot 'test/package-interface-v0.3.json'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("beamtrace-core-interface-{0}.json" -f [Guid]::NewGuid())

try {
    Push-Location $packageRoot
    try {
        & gleam export package-interface --out $temporary
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    finally {
        Pop-Location
    }

    $expected = [IO.File]::ReadAllBytes($snapshot)
    $actual = [IO.File]::ReadAllBytes($temporary)
    $matches = $expected.Length -eq $actual.Length
    for ($index = 0; $matches -and $index -lt $expected.Length; $index++) {
        if ($expected[$index] -ne $actual[$index]) { $matches = $false }
    }
    if (-not $matches) {
        throw 'beamtrace_core public API changed. Review it, then intentionally regenerate test/package-interface-v0.3.json.'
    }
}
finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}

Write-Host 'beamtrace_core package interface matches the v0.3 snapshot.'
exit 0
