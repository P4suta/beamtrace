# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [switch] $RequireElixir,
    [switch] $SkipBrowserE2E
)

$ErrorActionPreference = 'Stop'
$steps = @(
    'check-format.ps1',
    'test-brand.ps1',
    'test-core.ps1',
    'test-runtime.ps1',
    'test-mcp.ps1',
    'test-agent.ps1',
    'test-web.ps1',
    'test-tui.ps1',
    'test-tui-pty.ps1',
    'test-fixtures.ps1',
    'test-cli-smoke.ps1',
    'build-web.ps1',
    'test-package.ps1',
    'test-hex-package.ps1',
    'test-distribution-metadata.ps1',
    'test-oci.ps1',
    'test-release.ps1',
    'test-repository-governance.ps1',
    'test-docs.ps1'
)

if (-not $SkipBrowserE2E) {
    $steps += 'test-web-e2e.ps1'
}

$steps += 'test-cleanliness.ps1'

if ($RequireElixir) {
    $env:BEAMTRACE_REQUIRE_ELIXIR = '1'
}

foreach ($step in $steps) {
    Write-Host "TDD gate: $step"
    & (Join-Path $PSScriptRoot $step)
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

exit 0
