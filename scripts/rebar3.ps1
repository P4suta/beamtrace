# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $RebarArguments
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'ensure-rebar3.ps1')
& escript (Join-Path $repoRoot '.tools/rebar3') @RebarArguments
exit $LASTEXITCODE
