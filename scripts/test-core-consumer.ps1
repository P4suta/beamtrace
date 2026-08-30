# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'invoke-gleam-with-network-retry.ps1')
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.build'))
$workRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot "core-consumer-$PID"))
if (-not $workRoot.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe core consumer directory: $workRoot"
}

if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
try {
    $consumer = Join-Path $workRoot 'beamtrace_core_consumer'
    & gleam new $consumer --name beamtrace_core_consumer --skip-github
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated core consumer.' }

    $consumerToml = Join-Path $consumer 'gleam.toml'
    $corePath = (Join-Path $repoRoot 'packages/beamtrace_core').Replace('\', '/')
    $toml = Get-Content -Raw -LiteralPath $consumerToml
    $toml = $toml -replace '(?m)^gleam_stdlib = .+$', "gleam_stdlib = `">= 0.70.0 and < 2.0.0`"`nbeamtrace_core = { path = `"$corePath`" }"
    $toml | Set-Content -LiteralPath $consumerToml -Encoding utf8NoBOM
    Copy-Item -LiteralPath (Join-Path $repoRoot 'fixtures/hex_consumer.gleam') `
        -Destination (Join-Path $consumer 'src/beamtrace_core_consumer.gleam')

    Push-Location $consumer
    try {
        $expected = 'facade=checked dag_boundaries=1 diagnostic_messages=1 diff_changed=0 mfa=shop:checkout/1'
        $erlangRun = Invoke-GleamWithNetworkRetry -Arguments @('run', '--target', 'erlang')
        $erlangOutput = $erlangRun.Output.Trim()
        if ($erlangRun.ExitCode -ne 0 -or -not $erlangOutput.EndsWith($expected)) {
            throw "Isolated Erlang consumer failed:`n$erlangOutput"
        }
        $javascriptRun = Invoke-GleamWithNetworkRetry -Arguments @(
            'run', '--target', 'javascript', '--runtime', 'nodejs'
        )
        $javascriptOutput = $javascriptRun.Output.Trim()
        if ($javascriptRun.ExitCode -ne 0 -or -not $javascriptOutput.EndsWith($expected)) {
            throw "Isolated JavaScript consumer failed:`n$javascriptOutput"
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}

Write-Host 'Isolated Erlang and JavaScript core consumers passed.'
exit 0
