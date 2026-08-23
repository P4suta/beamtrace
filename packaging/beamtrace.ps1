# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $BeamTraceArguments
)

$ErrorActionPreference = 'Stop'
$installRoot = Split-Path -Parent $PSScriptRoot
$previousAgent = $env:BEAMTRACE_AGENT_BEAM
$previousWeb = $env:BEAMTRACE_WEB_ROOT
$previousErlLibs = $env:ERL_LIBS
try {
    $env:BEAMTRACE_AGENT_BEAM = Join-Path $installRoot 'lib/beamtrace_agent.beam'
    $env:BEAMTRACE_WEB_ROOT = Join-Path $installRoot 'share/beamtrace/web'
    $nativeRoot = Join-Path $installRoot 'lib/native'
    $env:ERL_LIBS = if ([string]::IsNullOrEmpty($previousErlLibs)) {
        $nativeRoot
    }
    else {
        "$nativeRoot$([IO.Path]::PathSeparator)$previousErlLibs"
    }
    & escript (Join-Path $installRoot 'lib/beamtrace.escript') @BeamTraceArguments
    $exitCode = $LASTEXITCODE
}
finally {
    $env:BEAMTRACE_AGENT_BEAM = $previousAgent
    $env:BEAMTRACE_WEB_ROOT = $previousWeb
    $env:ERL_LIBS = $previousErlLibs
}

exit $exitCode
