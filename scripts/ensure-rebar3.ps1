# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolDir = Join-Path $repoRoot '.tools'
$rebar = Join-Path $toolDir 'rebar3'
$expectedSha256 = 'AF85AAB41F9FD74BDD6341EBDF6FE9C88077AAB9F8EAC82371583FA02F2B0BDF'

New-Item -ItemType Directory -Path $toolDir -Force | Out-Null

$valid = $false
if (Test-Path -LiteralPath $rebar) {
    $actual = (Get-FileHash -LiteralPath $rebar -Algorithm SHA256).Hash
    $valid = $actual -eq $expectedSha256
}
if (-not $valid) {
    Invoke-WebRequest `
        -Uri 'https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3' `
        -OutFile $rebar
    $actual = (Get-FileHash -LiteralPath $rebar -Algorithm SHA256).Hash
    if ($actual -ne $expectedSha256) {
        throw "rebar3 checksum mismatch: $actual"
    }
}
