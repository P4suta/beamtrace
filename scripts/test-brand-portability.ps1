# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$brandGuard = Join-Path $PSScriptRoot 'test-brand.ps1'

& $brandGuard -ForcePowerShellSearch
if ($LASTEXITCODE -ne 0) {
    throw 'The PowerShell-only brand guard fallback failed.'
}

Write-Host 'Brand guard portability acceptance passed.'
exit 0
