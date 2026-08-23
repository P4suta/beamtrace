# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$buildRoot = Join-Path $repoRoot '.build'

$crashDumps = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter 'erl_crash.dump' | ForEach-Object {
    $_.FullName.Substring($repoRoot.Length + 1)
})
$packageTestDirectories = @()
if (Test-Path -LiteralPath $buildRoot -PathType Container) {
    $packageTestDirectories = @(Get-ChildItem -LiteralPath $buildRoot -Directory -Filter 'package-test-*' | ForEach-Object {
        $_.FullName.Substring($repoRoot.Length + 1)
    })
}

$residue = @($crashDumps + $packageTestDirectories)
if ($residue.Count -gt 0) {
    throw "Test residue must not remain in the worktree:`n$($residue -join "`n")"
}

Write-Host 'Worktree cleanliness acceptance passed.'
exit 0
