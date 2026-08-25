# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $repoRoot 'packages/beamtrace_runtime'
. (Join-Path $PSScriptRoot 'enable-msvc.ps1')
& (Join-Path $PSScriptRoot 'ensure-rebar3.ps1')
$env:PATH = "$PSScriptRoot$([IO.Path]::PathSeparator)$env:PATH"
$env:REBAR_CACHE_DIR = Join-Path $repoRoot '.cache/rebar3'

function Invoke-McpStdio {
    param([Parameter(Mandatory = $true)][string[]] $Messages)

    $gleam = (Get-Command gleam -ErrorAction Stop).Source
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $gleam
    $start.WorkingDirectory = $runtimeRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $start.ArgumentList.Add('run')
    $start.ArgumentList.Add('--')
    $start.ArgumentList.Add('mcp')

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        throw 'Could not start the MCP stdio process.'
    }
    foreach ($message in $Messages) {
        $process.StandardInput.WriteLine($message)
    }
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        $process.Kill($true)
        throw 'MCP stdio process did not exit after stdin closed.'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        throw "MCP stdio process failed: $stderr"
    }
    [PSCustomObject]@{ Stdout = $stdout; Stderr = $stderr }
}

$listed = Invoke-McpStdio @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"beamtrace-smoke","version":"1"}}}',
    '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
)
$lines = @($listed.Stdout -split "`r?`n" | Where-Object { $_ -ne '' })
if ($lines.Count -ne 2) {
    throw "MCP legacy initialize/list must contain exactly two JSON-RPC lines, got $($lines.Count): $($listed.Stdout)"
}
$initialized = $lines[0] | ConvertFrom-Json -Depth 32
if (
    $initialized.jsonrpc -ne '2.0' -or
    $initialized.id -ne 1 -or
    $initialized.result.protocolVersion -ne '2025-11-25'
) {
    throw 'MCP initialize response is malformed.'
}
$message = $lines[1] | ConvertFrom-Json -Depth 32
if ($message.jsonrpc -ne '2.0' -or $message.id -ne 2 -or $message.result.tools.Count -ne 4) {
    throw 'MCP tools/list response is malformed.'
}
foreach ($tool in $message.result.tools) {
    if ($tool.annotations.readOnlyHint -ne $true -or $tool.annotations.destructiveHint -ne $false) {
        throw "MCP tool is not read-only: $($tool.name)"
    }
}

$notified = Invoke-McpStdio @('{"jsonrpc":"2.0","method":"notifications/initialized"}')
if ($notified.Stdout -ne '') {
    throw "MCP notification unexpectedly wrote to stdout: $($notified.Stdout)"
}

$previousAgentBeam = $env:BEAMTRACE_AGENT_BEAM
try {
    $env:BEAMTRACE_AGENT_BEAM = & (Join-Path $PSScriptRoot 'build-agent.ps1')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & npm run test:mcp
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    $env:BEAMTRACE_AGENT_BEAM = $previousAgentBeam
}

exit 0
