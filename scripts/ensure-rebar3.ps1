# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolDir = Join-Path $repoRoot '.tools'
$rebar = Join-Path $toolDir 'rebar3'
# renovate: datasource=github-release-attachments depName=erlang/rebar3
$rebar3Version = '3.27.3'
$expectedSha256 = 'f1d87d78decfc56b87d971c75ee6355698ec0c49fadd57f2c056043b7ca291b5'

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
