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
