# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project-version.ps1')
$projectVersion = Get-BeamTraceVersion -RepositoryRoot $repoRoot
& (Join-Path $PSScriptRoot 'ensure-rebar3.ps1')
$env:PATH = "$PSScriptRoot$([IO.Path]::PathSeparator)$env:PATH"
$env:REBAR_CACHE_DIR = Join-Path $repoRoot '.cache/rebar3'
$previousTeam = $env:BEAMTRACE_TEAM

try {
    $launcher = Join-Path $PSScriptRoot 'beamtrace.ps1'
    $version = (& $launcher version | Out-String)
    if ($LASTEXITCODE -ne 0 -or $version -notmatch ([regex]::Escape("beamtrace $projectVersion"))) {
        throw 'version smoke test failed'
    }

    $help = (& $launcher help | Out-String)
    if ($LASTEXITCODE -ne 0 -or $help -notmatch 'capture') {
        throw 'help smoke test failed'
    }
    $captureHelp = (& $launcher help capture | Out-String)
    if ($LASTEXITCODE -ne 0 -or $captureHelp -notmatch '--acknowledge-seq-trace-reset') {
        throw 'capture help smoke test failed'
    }
    $relayHelp = (& $launcher help relay | Out-String)
    if ($LASTEXITCODE -ne 0 -or $relayHelp -notmatch '--raw-grant-file PATH') {
        throw 'relay help smoke test failed'
    }

    $doctor = (& $launcher doctor | Out-String)
    if ($LASTEXITCODE -ne 0 -or $doctor -notmatch 'isolated trace session: true') {
        throw 'doctor smoke test failed: OTP 27+ isolated trace sessions are required'
    }
    if ($doctor -notmatch 'agent BEAM: valid') {
        throw 'doctor smoke test failed: a validated agent BEAM is required'
    }
    if ($doctor -notmatch 'web assets: valid') {
        throw 'doctor smoke test failed: built Web assets are required'
    }

    $human = (& $launcher validate nope.beamtrace 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 2 -or $human -notmatch 'beamtrace\[E_ARCHIVE_NOT_FOUND\]') {
        throw "validate must report a missing archive as E_ARCHIVE_NOT_FOUND: $human"
    }
    $machine = (& $launcher validate nope.beamtrace --json | Out-String | ConvertFrom-Json)
    if ($machine.error.code -ne 'archive_not_found' -or $human -notmatch ([regex]::Escape("Next: $($machine.error.hint)"))) {
        throw "validate human hint must match the JSON hint: $human"
    }

    $previousAgentBeam = $env:BEAMTRACE_AGENT_BEAM
    $env:BEAMTRACE_AGENT_BEAM = Join-Path $repoRoot '.build/does-not-exist.beam'
    try {
        Push-Location (Join-Path $repoRoot 'packages/beamtrace_runtime')
        try {
            $preflightStart = Get-Date
            $preflight = (& gleam run -- record --trigger 'erlang:system_time/0' --no-ui -- erl -noshell -eval 'halt().' 2>&1 | Out-String)
            $preflightExit = $LASTEXITCODE
            $preflightSeconds = ((Get-Date) - $preflightStart).TotalSeconds
            if ($preflightExit -ne 2 -or $preflight -notmatch 'beamtrace\[E_AGENT_BEAM_UNAVAILABLE\]' -or $preflight -notmatch 'mise run beamtrace') {
                throw "record must fail fast without an agent BEAM: $preflight"
            }
            $preflightJson = (& gleam run -- record --trigger 'erlang:system_time/0' --no-ui --json -- erl -noshell -eval 'halt().' | Out-String | ConvertFrom-Json)
            if ($preflightJson.error.code -ne 'agent_beam_unavailable') {
                throw "record --json must report agent_beam_unavailable: $($preflightJson | ConvertTo-Json -Compress)"
            }
        }
        finally {
            Pop-Location
        }
    }
    finally {
        if ($null -eq $previousAgentBeam) { Remove-Item Env:BEAMTRACE_AGENT_BEAM -ErrorAction SilentlyContinue } else { $env:BEAMTRACE_AGENT_BEAM = $previousAgentBeam }
    }

    $demo = (& $launcher demo --no-ui --json | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "demo smoke test failed (exit $LASTEXITCODE): $demo"
    }
    $demoResult = $demo | ConvertFrom-Json
    if ($demoResult.command -ne 'demo' -or -not $demoResult.ok -or $demoResult.artifact.event_count -lt 1) {
        throw "demo smoke test did not report a sealed archive: $demo"
    }

    $env:BEAMTRACE_TEAM = 'true'
    $teamFailure = (& $launcher serve 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 2 -or $teamFailure -notmatch 'invalid team configuration') {
        throw 'team serve must fail closed before listening when required OIDC configuration is absent'
    }
}
finally {
    if ($null -eq $previousTeam) {
        Remove-Item Env:BEAMTRACE_TEAM -ErrorAction SilentlyContinue
    }
    else {
        $env:BEAMTRACE_TEAM = $previousTeam
    }
}

exit 0
