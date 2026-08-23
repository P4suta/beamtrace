# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [switch] $ContainerBoundary
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project-version.ps1')
$projectVersion = Get-BeamTraceVersion -RepositoryRoot $repoRoot
$coreRoot = Join-Path $repoRoot 'packages/beamtrace_core'
$manifest = Join-Path $coreRoot 'gleam.toml'
$readme = Join-Path $coreRoot 'README.md'
$license = Join-Path $coreRoot 'LICENSE'

$manifestText = Get-Content -Raw -LiteralPath $manifest
foreach ($marker in @(
    'name = "beamtrace_core"',
    "version = `"$projectVersion`"",
    'licences = ["Apache-2.0", "MIT"]',
    'description = "Target-independent causal trace contracts and analysis for BeamTrace"',
    '[repository]',
    'type = "github"',
    'user = "P4suta"',
    'repo = "beamtrace"',
    'path = "packages/beamtrace_core"'
)) {
    if (-not $manifestText.Contains($marker)) {
        throw "Hex package metadata is missing: $marker"
    }
}
if (-not (Test-Path -LiteralPath $readme -PathType Leaf)) {
    throw 'The Hex package must include a package README.'
}
if (-not (Test-Path -LiteralPath $license -PathType Leaf)) {
    throw 'The Hex package must include its complete dual-licence text.'
}
$readmeText = Get-Content -Raw -LiteralPath $readme
foreach ($marker in @('gleam add beamtrace_core', 'https://hexdocs.pm/beamtrace_core/')) {
    if (-not $readmeText.Contains($marker)) {
        throw "The Hex README is missing: $marker"
    }
}
$licenseText = Get-Content -Raw -LiteralPath $license
foreach ($marker in @('Apache License', 'TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION', 'MIT License', 'Permission is hereby granted')) {
    if (-not $licenseText.Contains($marker)) {
        throw "The Hex package licence file is incomplete: $marker"
    }
}
foreach ($relative in @('LICENSES/Apache-2.0.txt', 'LICENSES/MIT.txt')) {
    $canonical = (Get-Content -Raw -LiteralPath (Join-Path $repoRoot $relative)).Trim()
    if (-not $licenseText.Contains($canonical)) {
        throw "The Hex package does not include the complete canonical licence: $relative"
    }
}

$tarball = Join-Path $coreRoot "build/beamtrace_core-$projectVersion.tar"
if ($ContainerBoundary) {
    $mount = "${repoRoot}:/src"
    & docker run --rm --volume $mount --workdir /src/packages/beamtrace_core `
        ghcr.io/gleam-lang/gleam:v1.18.1-erlang-alpine gleam export hex-tarball
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
elseif (-not $IsWindows) {
    Push-Location $coreRoot
    try {
        $exportOutput = (& gleam export hex-tarball 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $exportOutput -match '(?m)^error:') {
            throw "Hex tarball export failed:`n$exportOutput"
        }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host 'Hex acceptance: Windows validates metadata; Linux CI performs the native export boundary.'
    exit 0
}

if (-not (Test-Path -LiteralPath $tarball -PathType Leaf)) {
    throw 'Hex tarball was not generated.'
}
$tempRoot = Join-Path $repoRoot '.build/hex-acceptance'
$resolvedBuild = [IO.Path]::GetFullPath((Join-Path $repoRoot '.build'))
$resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
if (-not $resolvedTemp.StartsWith($resolvedBuild, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe Hex inspection directory: $resolvedTemp"
}
if (Test-Path -LiteralPath $resolvedTemp) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
New-Item -ItemType Directory -Path $resolvedTemp -Force | Out-Null
try {
    & tar -xf $tarball -C $resolvedTemp contents.tar.gz
    if ($LASTEXITCODE -ne 0) { throw 'Could not extract the Hex package contents archive.' }
    $contents = @(& tar -tzf (Join-Path $resolvedTemp 'contents.tar.gz'))
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the Hex package contents.' }
    foreach ($required in @('gleam.toml', 'README.md', 'LICENSE', 'src/beamtrace/types.gleam')) {
        if ($required -notin $contents) { throw "Hex package is missing: $required" }
    }
    if ($contents | Where-Object { $_ -match '(^|/)(test|build)/' -or $_ -match '(^|/)(manifest\.toml|\.github)(/|$)' }) {
        throw 'Hex package includes test, build, lockfile, or repository-automation files.'
    }
    & tar -xf $tarball -C $resolvedTemp metadata.config
    if ($LASTEXITCODE -ne 0) { throw 'Could not extract Hex package metadata.' }
    $metadata = Get-Content -Raw -LiteralPath (Join-Path $resolvedTemp 'metadata.config')
    foreach ($marker in @('https://github.com/P4suta/beamtrace', 'Apache-2.0', 'MIT')) {
        if (-not $metadata.Contains($marker)) {
            throw "Hex tarball metadata is missing: $marker"
        }
    }
}
finally {
    if (Test-Path -LiteralPath $resolvedTemp) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

Write-Host 'Hex package acceptance passed.'
exit 0
