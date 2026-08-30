# SPDX-License-Identifier: Apache-2.0 OR MIT
# The Web distribution is checked in; a build must reproduce it byte for byte.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'build-web.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$stale = @(git -C $repoRoot status --porcelain -- packages/beamtrace_web/dist)
if ($stale.Count -ne 0) {
    throw "packages/beamtrace_web/dist is stale; run scripts/build-web.ps1 and commit:`n$($stale -join "`n")"
}
Write-Host 'Checked-in Web distribution matches its sources.'
exit 0
