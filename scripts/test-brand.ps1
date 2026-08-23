# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$expectedRootName = 'beamtrace'
$legacyName = -join @([char]97, [char]102, [char]116, [char]101, [char]114, [char]103, [char]108, [char]111, [char]119)
$legacyExtension = -join @('.', [char]97, [char]103, 'trace')
$exclusions = @(
    '-g', '!**/.build/**',
    '-g', '!**/build/**',
    '-g', '!**/_build/**',
    '-g', '!**/.lustre/**',
    '-g', '!**/node_modules/**',
    '-g', '!playwright-report/**',
    '-g', '!test-results/**',
    '-g', '!**/manifest.toml',
    '-g', '!**/*.beam'
)

Push-Location $repoRoot
try {
    $contentMatches = @(& rg -i -l --hidden @exclusions -- $legacyName .)
    if ($LASTEXITCODE -gt 1) { throw 'Brand content scan failed.' }
    $extensionMatches = @(& rg -i -l --hidden @exclusions -- ([regex]::Escape($legacyExtension)) .)
    if ($LASTEXITCODE -gt 1) { throw 'Trace-extension scan failed.' }
    $sourcePaths = @(& rg --files -uu @exclusions)
    if ($LASTEXITCODE -ne 0) { throw 'Brand path scan failed.' }
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
