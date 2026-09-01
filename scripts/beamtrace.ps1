# SPDX-License-Identifier: Apache-2.0 OR MIT
# No param()/CmdletBinding: PowerShell would otherwise claim arguments such
# as --out (ambiguous with -OutVariable) instead of passing them through.
$BeamTraceArguments = @($args)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'enable-msvc.ps1')
& (Join-Path $PSScriptRoot 'ensure-rebar3.ps1')
$env:PATH = "$PSScriptRoot;$env:PATH"
$env:REBAR_CACHE_DIR = Join-Path $repoRoot '.cache\rebar3'
$previousAgentBeam = $env:BEAMTRACE_AGENT_BEAM
$previousWebRoot = $env:BEAMTRACE_WEB_ROOT
$agentBeam = & (Join-Path $PSScriptRoot 'build-agent.ps1')
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
$env:BEAMTRACE_AGENT_BEAM = $agentBeam
$env:BEAMTRACE_WEB_ROOT = Join-Path $repoRoot 'packages/beamtrace_web/dist'

Push-Location (Join-Path $repoRoot 'packages\beamtrace_runtime')
try {
    & gleam run -- @BeamTraceArguments
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
    $env:BEAMTRACE_AGENT_BEAM = $previousAgentBeam
    $env:BEAMTRACE_WEB_ROOT = $previousWebRoot
}

exit $exitCode
