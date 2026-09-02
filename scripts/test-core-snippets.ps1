# SPDX-License-Identifier: Apache-2.0 OR MIT
# Compile every Gleam block in the core README on both targets, and run the
# examples/ projects against their pinned output.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'invoke-gleam-with-network-retry.ps1')
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.build'))
$workRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot "core-snippets-$PID"))
if (-not $workRoot.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe snippet directory: $workRoot"
}

if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
try {
    $project = Join-Path $workRoot 'beamtrace_core_snippets'
    & gleam new $project --name beamtrace_core_snippets --skip-github
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated snippet project.' }

    $projectToml = Join-Path $project 'gleam.toml'
    $corePath = (Join-Path $repoRoot 'packages/beamtrace_core').Replace('\', '/')
    $toml = Get-Content -Raw -LiteralPath $projectToml
    $toml = $toml -replace '(?m)^gleam_stdlib = .+$', "gleam_stdlib = `">= 0.70.0 and < 2.0.0`"`nbeamtrace_core = { path = `"$corePath`" }"
    $toml | Set-Content -LiteralPath $projectToml -Encoding utf8NoBOM
    Remove-Item -LiteralPath (Join-Path $project 'src/beamtrace_core_snippets.gleam')

    & node (Join-Path $PSScriptRoot 'extract-readme-snippets.mjs') `
        (Join-Path $repoRoot 'packages/beamtrace_core/README.md') `
        (Join-Path $project 'src')
    if ($LASTEXITCODE -ne 0) { throw 'README snippet extraction failed.' }
    $snippets = Get-ChildItem -LiteralPath (Join-Path $project 'src') -Filter 'snippet_*.gleam'
    if ($snippets.Count -lt 3) {
        throw "Expected at least 3 README snippets, found $($snippets.Count)."
    }

    Push-Location $project
    try {
        foreach ($target in @('erlang', 'javascript')) {
            $build = Invoke-GleamWithNetworkRetry -Arguments @('build', '--target', $target)
            if ($build.ExitCode -ne 0) {
                throw "README snippets do not compile on ${target}:`n$($build.Output)"
            }
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}

$examples = [ordered]@{
    'decode_and_compare' = 'changed=0 added=0 events=2'
    'build_events' = 'validated=true roundtrip=ok'
    'query_language' = 'suggestion=message.tag residual=some'
    'diagnostics_thresholds' = 'default=0 tuned=1'
}
foreach ($entry in $examples.GetEnumerator()) {
    $exampleRoot = Join-Path $repoRoot "examples/$($entry.Key)"
    Push-Location $exampleRoot
    try {
        foreach ($target in @('erlang', 'javascript')) {
            $arguments = @('run', '--target', $target)
            if ($target -eq 'javascript') { $arguments += @('--runtime', 'nodejs') }
            $run = Invoke-GleamWithNetworkRetry -Arguments $arguments
            $lastLine = ($run.Output.Trim() -split "`n")[-1].Trim()
            if ($run.ExitCode -ne 0 -or $lastLine -ne $entry.Value) {
                throw "examples/$($entry.Key) on $target printed '$lastLine', expected '$($entry.Value)'."
            }
        }
    }
    finally {
        Pop-Location
    }
}

Write-Host 'README snippets compile and every example prints its pinned output.'
exit 0
