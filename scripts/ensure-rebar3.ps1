# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolDir = Join-Path $repoRoot '.tools'
$rebar = Join-Path $toolDir 'rebar3'
# renovate: datasource=github-release-attachments depName=erlang/rebar3
$rebar3Version = '3.27.1'
$expectedSha256 = '708407032479514dd68b581a0b09a68b5a781fb6f53dcf4ad81ce4ef6b92940f'

New-Item -ItemType Directory -Path $toolDir -Force | Out-Null

$valid = $false
if (Test-Path -LiteralPath $rebar) {
    $actual = (Get-FileHash -LiteralPath $rebar -Algorithm SHA256).Hash
    $valid = $actual -eq $expectedSha256
}
if (-not $valid) {
    Invoke-WebRequest `
        -Uri "https://github.com/erlang/rebar3/releases/download/$rebar3Version/rebar3" `
        -OutFile $rebar
    $actual = (Get-FileHash -LiteralPath $rebar -Algorithm SHA256).Hash
    if ($actual -ne $expectedSha256) {
        throw "rebar3 checksum mismatch: $actual"
    }
}
