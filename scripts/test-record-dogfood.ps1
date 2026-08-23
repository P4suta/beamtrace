# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [string]$Launcher
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.build'))
$workRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot "record-dogfood-$PID"))
if (-not $workRoot.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe dogfood work directory: $workRoot"
}

$fixtureRoot = Join-Path $workRoot 'fixture'
$tracePath = Join-Path $workRoot 'record.beamtrace'
$jsonlPath = Join-Path $workRoot 'record.jsonl'
$inspectRoot = Join-Path $workRoot 'inspect'
$previousCleanupAssertion = $env:BEAMTRACE_RECORD_ASSERT_CLEANUP
$resolvedLauncher = $null
if (-not [string]::IsNullOrWhiteSpace($Launcher)) {
    $resolvedLauncher = [IO.Path]::GetFullPath($Launcher)
    if (-not (Test-Path -LiteralPath $resolvedLauncher -PathType Leaf)) {
        throw "BeamTrace dogfood launcher does not exist: $resolvedLauncher"
    }
}
$erlCommand = (Get-Command erl -ErrorAction Stop).Source

New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
try {
    & erlc +debug_info -Werror -o $fixtureRoot (Join-Path $repoRoot 'agent/test/beamtrace_agent_fixture.erl')
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the record dogfood fixture.' }

    $hostName = [Net.Dns]::GetHostName()
    if ($hostName -notmatch '^[A-Za-z0-9_-]+$') {
        throw "The local short node hostname is unsafe: $hostName"
    }
    $node = "beamtrace_record_$PID@$hostName"
    $expression = "P=spawn(fun()->beamtrace_agent_fixture:filtered_trigger({allowed,2}) end),R=erlang:monitor(process,P),receive {'DOWN',R,process,P,_}->ok end."
    $env:BEAMTRACE_RECORD_ASSERT_CLEANUP = '1'
    $recordArguments = @(
        'record', '--node', $node,
        '--trigger', 'beamtrace_agent_fixture:filtered_trigger/1',
        '--out', $tracePath.Replace('\', '/'),
        '--', $erlCommand, '-noshell', '-pa', $fixtureRoot.Replace('\', '/'),
        '-eval', $expression, '-s', 'init', 'stop'
    )
    if ($null -eq $resolvedLauncher) {
        & (Join-Path $PSScriptRoot 'beamtrace.ps1') -BeamTraceArguments $recordArguments
    }
    else {
        & $resolvedLauncher @recordArguments
    }
    if ($LASTEXITCODE -ne 0) { throw "Record dogfood failed with exit code $LASTEXITCODE." }
    if (-not (Test-Path -LiteralPath $tracePath -PathType Leaf)) {
        throw 'Record dogfood did not produce a trace archive.'
    }

    $exportArguments = @(
        'export', $tracePath.Replace('\', '/'), '--format', 'jsonl'
    )
    if ($null -eq $resolvedLauncher) {
        & (Join-Path $PSScriptRoot 'beamtrace.ps1') -BeamTraceArguments $exportArguments
    }
    else {
        & $resolvedLauncher @exportArguments
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $jsonlPath -PathType Leaf)) {
        throw 'Record dogfood JSONL export failed.'
    }

    $eventLines = @(Get-Content -LiteralPath $jsonlPath)
    $events = @($eventLines | ForEach-Object { $_ | ConvertFrom-Json })
    if ($events.Count -lt 2 -or $events.Count -gt 16) {
        throw "Record dogfood produced an unexpected event count: $($events.Count)"
    }
    $kinds = @($events | ForEach-Object { $_.event.kind })
    if (@($kinds | Where-Object { $_ -eq 'root' }).Count -ne 1 -or $kinds -notcontains 'exit') {
        throw "Record dogfood did not preserve the root/exit causal boundary: $($kinds -join ',')"
    }
    $encoded = $eventLines -join "`n"
    if ($encoded.Contains('"display":"') -or $encoded.Contains('SENTINEL-secret-never-leak')) {
        throw 'Metadata dogfood exported a scalar display or sentinel secret.'
    }

    Expand-Archive -LiteralPath $tracePath -DestinationPath $inspectRoot -Force
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $inspectRoot 'manifest.json') | ConvertFrom-Json
    if ($manifest.completeness.kind -ne 'complete' -or $manifest.privacy.kind -ne 'metadata') {
        throw 'Record dogfood archive is incomplete or not metadata-only.'
    }

    Write-Host "Record dogfood passed: $($events.Count) events, complete, metadata-only, cleanup verified in target VM."
}
finally {
    $env:BEAMTRACE_RECORD_ASSERT_CLEANUP = $previousCleanupAssertion
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}

exit 0
