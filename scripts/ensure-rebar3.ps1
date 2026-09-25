# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolDir = Join-Path $repoRoot '.tools'
$rebar = Join-Path $toolDir 'rebar3'
# renovate: datasource=github-release-attachments depName=erlang/rebar3
$rebar3Version = '3.27.0'
$expectedSha256 = 'af85aab41f9fd74bdd6341ebdf6fe9c88077aab9f8eac82371583fa02f2b0bdf'

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
