# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-gleam-with-network-retry.ps1')

$script:attempts = 0
$script:mode = 'transient-then-success'
function gleam {
    $script:attempts++
    if ($script:mode -eq 'transient-then-success' -and $script:attempts -ge 3) {
        $global:LASTEXITCODE = 0
        Write-Output 'consumer-ok'
        return
    }
    if ($script:mode -eq 'non-network') {
        $global:LASTEXITCODE = 2
        Write-Output 'Gleam compilation failed'
        return
    }

    $global:LASTEXITCODE = 75
    Write-Output 'A HTTP request failed: error sending request for url'
}

$result = Invoke-GleamWithNetworkRetry `
    -Arguments @('run') `
    -MaximumAttempts 3 `
    -RetryDelayMilliseconds 0
if (
    $result.ExitCode -ne 0 -or
    $result.Output.Trim() -ne 'consumer-ok' -or
    $script:attempts -ne 3
) {
    throw 'A transient registry failure was not retried to success exactly twice.'
}

$script:attempts = 0
$script:mode = 'non-network'
$result = Invoke-GleamWithNetworkRetry `
    -Arguments @('test') `
    -MaximumAttempts 3 `
    -RetryDelayMilliseconds 0
if ($result.ExitCode -ne 2 -or $script:attempts -ne 1) {
    throw 'A non-network Gleam failure was retried or its exit code was lost.'
}

$script:attempts = 0
$script:mode = 'transient-always'
$result = Invoke-GleamWithNetworkRetry `
    -Arguments @('run') `
    -MaximumAttempts 3 `
    -RetryDelayMilliseconds 0
if ($result.ExitCode -ne 75 -or $script:attempts -ne 3) {
    throw 'The transient Gleam retry was not bounded to its configured attempts.'
}

Write-Host 'Bounded Gleam registry/network retry contracts passed.'
exit 0
