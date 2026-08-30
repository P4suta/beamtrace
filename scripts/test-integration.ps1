# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$missing = @('erl', 'epmd') | Where-Object {
    $null -eq (Get-Command $_ -ErrorAction SilentlyContinue)
}
if ($null -eq (Get-Command rebar3 -ErrorAction SilentlyContinue)) {
    $missing += 'rebar3'
}
else {
    & rebar3 version *> $null
    if ($LASTEXITCODE -ne 0) { $missing += 'rebar3' }
}
if ($null -eq (Get-Command mix -ErrorAction SilentlyContinue)) {
    $missing += 'mix'
}
else {
    & mix --version *> $null
    if ($LASTEXITCODE -ne 0) { $missing += 'mix' }
}
if ($missing.Count -gt 0) {
    Write-Host "SKIP integration: missing optional prerequisites: $($missing -join ', ')"
    exit 0
}

& erl -noshell -eval 'case gen_tcp:listen(0, [{ip,{127,0,0,1}}]) of {ok,S} -> gen_tcp:close(S), halt(0); _ -> halt(1) end.'
if ($LASTEXITCODE -ne 0) {
    Write-Host 'SKIP integration: this environment does not permit loopback sockets'
    exit 0
}

& epmd -daemon
& epmd -names *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'SKIP integration: EPMD cannot start in this environment'
    exit 0
}

Push-Location (Join-Path $repoRoot 'packages/beamtrace_runtime')
try {
    & gleam test -- --integration
    exit $LASTEXITCODE
}
finally { Pop-Location }
