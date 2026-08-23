# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [switch] $ForcePowerShellSearch
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$expectedRootName = 'beamtrace'
$legacyName = -join @([char]97, [char]102, [char]116, [char]101, [char]114, [char]103, [char]108, [char]111, [char]119)
$legacyExtension = -join @('.', [char]97, [char]103, 'trace')
$exclusions = @(
    '-g', '!**/.git/**',
    '-g', '!**/.build/**',
    '-g', '!**/build/**',
    '-g', '!**/_build/**',
    '-g', '!**/.cache/**',
    '-g', '!**/.tools/**',
    '-g', '!**/.lustre/**',
    '-g', '!**/node_modules/**',
    '-g', '!playwright-report/**',
    '-g', '!test-results/**',
    '-g', '!**/manifest.toml',
    '-g', '!**/*.beam'
)

function Get-FallbackSourceFiles {
    $skipDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('.git', '.build', 'build', '_build', '.cache', '.tools', '.lustre', 'node_modules', 'playwright-report', 'test-results')) {
        [void] $skipDirectories.Add($name)
    }

    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push((Get-Item -LiteralPath $repoRoot))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($child in Get-ChildItem -Force -LiteralPath $directory.FullName) {
            if ($child.PSIsContainer) {
                if ($skipDirectories.Contains($child.Name)) { continue }
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $pending.Push($child)
                continue
            }
            if ($child.Name -ieq 'manifest.toml' -or $child.Extension -ieq '.beam') { continue }
            $files.Add($child)
        }
    }
    return $files
}

function Find-FallbackContentMatches {
    param(
        [Parameter(Mandatory)] [IO.FileInfo[]] $Files,
        [Parameter(Mandatory)] [string] $Needle
    )

    $binaryExtensions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in @('.beamtrace', '.dll', '.exe', '.gz', '.ico', '.jpg', '.jpeg', '.png', '.tar', '.zip')) {
        [void] $binaryExtensions.Add($extension)
    }

    $matches = [Collections.Generic.List[string]]::new()
    foreach ($file in $Files) {
        if ($binaryExtensions.Contains($file.Extension)) { continue }
        $content = [IO.File]::ReadAllText($file.FullName)
        if ($content.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $matches.Add([IO.Path]::GetRelativePath($repoRoot, $file.FullName))
        }
    }
    return $matches
}

Push-Location $repoRoot
try {
    $ripgrep = Get-Command rg -ErrorAction SilentlyContinue
    if (-not $ForcePowerShellSearch -and $null -ne $ripgrep) {
        $contentMatches = @(& $ripgrep.Source -i -l --hidden @exclusions -- $legacyName .)
        if ($LASTEXITCODE -gt 1) { throw 'Brand content scan failed.' }
        $extensionMatches = @(& $ripgrep.Source -i -l --hidden @exclusions -- ([regex]::Escape($legacyExtension)) .)
        if ($LASTEXITCODE -gt 1) { throw 'Trace-extension scan failed.' }
        $sourcePaths = @(& $ripgrep.Source --files -uu @exclusions)
        if ($LASTEXITCODE -ne 0) { throw 'Brand path scan failed.' }
    } else {
        $sourceFiles = @(Get-FallbackSourceFiles)
        $contentMatches = @(Find-FallbackContentMatches -Files $sourceFiles -Needle $legacyName)
        $extensionMatches = @(Find-FallbackContentMatches -Files $sourceFiles -Needle $legacyExtension)
        $sourcePaths = @($sourceFiles | ForEach-Object { [IO.Path]::GetRelativePath($repoRoot, $_.FullName) })
    }
}
finally {
    Pop-Location
}

$legacyPaths = @($sourcePaths | Where-Object {
    $_.IndexOf($legacyName, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
    $_.IndexOf($legacyExtension, [StringComparison]::OrdinalIgnoreCase) -ge 0
})
$violations = @($contentMatches + $extensionMatches + $legacyPaths | Sort-Object -Unique)
if ($violations.Count -gt 0) {
    throw "Legacy brand identifiers remain:`n$($violations -join "`n")"
}

if ([IO.Path]::GetFileName($repoRoot) -cne $expectedRootName) {
    throw "Repository directory must be named $expectedRootName."
}

$requiredPaths = @(
    'packages/beamtrace_core/gleam.toml',
    'packages/beamtrace_runtime/gleam.toml',
    'packages/beamtrace_web/gleam.toml',
    'packages/beamtrace_tui/gleam.toml',
    'agent/src/beamtrace_agent.erl',
    'scripts/beamtrace.ps1'
)
foreach ($relative in $requiredPaths) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $relative) -PathType Leaf)) {
        throw "Renamed project path is missing: $relative"
    }
}

$readme = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'README.md')
foreach ($marker in @('# BeamTrace', '`beamtrace`', '.beamtrace')) {
    if (-not $readme.Contains($marker)) {
        throw "README is missing renamed marker: $marker"
    }
}

Write-Host 'BeamTrace brand acceptance passed.'
exit 0
