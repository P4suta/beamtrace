# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot '.build/agent-runtime'
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
$resolvedRepo = [IO.Path]::GetFullPath($repoRoot)
if (-not $resolvedOutput.StartsWith($resolvedRepo, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Agent output directory must remain inside the repository: $resolvedOutput"
}

New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$source = Join-Path $repoRoot 'agent/src/beamtrace_agent.erl'
& erlc +debug_info +deterministic -Werror -o $resolvedOutput $source
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$beam = Join-Path $resolvedOutput 'beamtrace_agent.beam'
if (-not (Test-Path -LiteralPath $beam -PathType Leaf)) {
    throw "Agent compiler did not produce $beam"
}

Write-Output $beam
