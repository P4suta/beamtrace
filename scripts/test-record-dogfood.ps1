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
$gleamTracePath = Join-Path $workRoot 'record-gleam.beamtrace'
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

function Invoke-CheckedBeamTrace {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Description
    )

    $output = if ($null -eq $resolvedLauncher) {
        (& (Join-Path $PSScriptRoot 'beamtrace.ps1') -BeamTraceArguments $Arguments 2>&1 | Out-String)
    }
    else {
        (& $resolvedLauncher @Arguments 2>&1 | Out-String)
    }
    $status = $LASTEXITCODE
    if (-not [string]::IsNullOrEmpty($output)) {
        Write-Host $output.TrimEnd()
    }
    if ($status -ne 0) {
        throw "$Description failed with exit code $status."
    }
    if ($output -match '(?im)^(escript:\s+Internal error:|Runtime terminating during boot|=CRASH REPORT====|=ERROR REPORT====|=SUPERVISOR REPORT====)') {
        throw "$Description emitted an internal BEAM failure despite exiting successfully."
    }
}

New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
try {
    & erlc +debug_info -Werror -o $fixtureRoot (Join-Path $repoRoot 'agent/test/beamtrace_agent_fixture.erl')
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the record dogfood fixture.' }

    $hostName = [Net.Dns]::GetHostName()
    if ($hostName -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "The local node hostname is unsafe: $hostName"
    }
    $node = "beamtrace_record_$PID@$hostName"
    $expression = "P=spawn(fun()->beamtrace_agent_fixture:filtered_trigger({allowed,2}) end),R=erlang:monitor(process,P),receive {'DOWN',R,process,P,_}->ok end."
    $env:BEAMTRACE_RECORD_ASSERT_CLEANUP = '1'
    $recordArguments = @(
        'record', '--node', $node,
        '--trigger', 'beamtrace_agent_fixture:filtered_trigger/1',
        '--out', $tracePath.Replace('\', '/'),
        '--', $erlCommand, '-noshell', '-pa', $fixtureRoot.Replace('\', '/'),
        '-eval', $expression
    )
    Invoke-CheckedBeamTrace -Arguments $recordArguments -Description 'Direct Erlang record dogfood'
    if (-not (Test-Path -LiteralPath $tracePath -PathType Leaf)) {
        throw 'Record dogfood did not produce a trace archive.'
    }

    $exportArguments = @(
        'export', $tracePath.Replace('\', '/'), '--format', 'jsonl'
    )
    Invoke-CheckedBeamTrace -Arguments $exportArguments -Description 'Record dogfood JSONL export'
    if (-not (Test-Path -LiteralPath $jsonlPath -PathType Leaf)) {
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

    $gleamCommand = (Get-Command gleam -ErrorAction Stop).Source
    if ($null -ne $resolvedLauncher) {
        Push-Location (Join-Path $repoRoot 'packages/beamtrace_runtime')
        try {
            & $gleamCommand clean
            if ($LASTEXITCODE -ne 0) {
                throw "Could not clean the Gleam wrapper fixture, exit code $LASTEXITCODE."
            }
        }
        finally {
            Pop-Location
        }
    }
    $gleamRecordArguments = @(
        'record',
        '--trigger', 'beamtrace_demo_fixture:run/0',
        '--out', $gleamTracePath.Replace('\', '/'),
        '--', $gleamCommand, 'run', '--no-print-progress', '-m', 'beamtrace_record_fixture'
    )
    Push-Location (Join-Path $repoRoot 'packages/beamtrace_runtime')
    try {
        Invoke-CheckedBeamTrace -Arguments $gleamRecordArguments -Description 'Gleam-wrapper record dogfood'
    }
    finally {
        Pop-Location
    }
    if (-not (Test-Path -LiteralPath $gleamTracePath -PathType Leaf)) {
        throw 'Gleam-wrapper record dogfood did not produce a trace archive.'
    }
    $gleamInspectRoot = Join-Path $workRoot 'inspect-gleam'
    Expand-Archive -LiteralPath $gleamTracePath -DestinationPath $gleamInspectRoot -Force
    $gleamManifest = Get-Content -Raw -LiteralPath (Join-Path $gleamInspectRoot 'manifest.json') | ConvertFrom-Json
    $gleamEventLines = @(
        Get-ChildItem -LiteralPath (Join-Path $gleamInspectRoot 'events') -File -Filter '*.ndjson' |
            Sort-Object Name |
            Get-Content
    )
    if (
        $gleamManifest.completeness.kind -ne 'complete' -or
        $gleamManifest.privacy.kind -ne 'metadata' -or
        $gleamEventLines.Count -lt 1
    ) {
        throw 'Gleam-wrapper record dogfood archive is empty, incomplete, or not metadata-only.'
    }

    Write-Host "Record dogfood passed: direct erl and gleam run/shim captures are complete, metadata-only, and cleanup-verified."
}
finally {
    $env:BEAMTRACE_RECORD_ASSERT_CLEANUP = $previousCleanupAssertion
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}

exit 0
