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

# Build in the package directory, but run from the caller's directory so
# relative paths and beamtrace.toml discovery behave like the shipped CLI.
# Build output stays off stdout so `beamtrace ... --json | ConvertFrom-Json`
# pipelines see only the CLI's own output.
$runtimeRoot = Join-Path $repoRoot 'packages\beamtrace_runtime'
try {
    Push-Location $runtimeRoot
    try {
        $exportOutput = & gleam export escript 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $exportOutput | Out-String | Write-Error
        }
    }
    finally {
        Pop-Location
    }
    if ($exitCode -eq 0) {
        & escript (Join-Path $runtimeRoot 'beamtrace_runtime') @BeamTraceArguments
        $exitCode = $LASTEXITCODE
    }
}
finally {
    $env:BEAMTRACE_AGENT_BEAM = $previousAgentBeam
    $env:BEAMTRACE_WEB_ROOT = $previousWebRoot
}

exit $exitCode
