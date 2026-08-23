# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version,
    [Parameter(Mandatory)]
    [string] $Tarball,
    [string] $RepositoryRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$repoRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
    throw "Release source root is missing: $repoRoot"
}
$versionReader = Join-Path $repoRoot 'scripts/project-version.ps1'
if (-not (Test-Path -LiteralPath $versionReader -PathType Leaf)) {
    throw "Release source version reader is missing: $versionReader"
}
. $versionReader
$projectVersion = Get-BeamTraceVersion -RepositoryRoot $repoRoot
if ($Version -ne $projectVersion) {
    throw "Requested Hex version $Version does not match project version $projectVersion."
}
$localTarball = [IO.Path]::GetFullPath($Tarball)
if (-not (Test-Path -LiteralPath $localTarball -PathType Leaf)) {
    throw "Hex tarball is missing: $localTarball"
}
if ([IO.Path]::GetFileName($localTarball) -ne "beamtrace_core-$Version.tar") {
    throw "Hex tarball has an unexpected name: $localTarball"
}

$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.build'))
$tempRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot "hex-publish-$PID"))
if (-not $tempRoot.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe Hex comparison directory: $tempRoot"
}

function Get-HexContentsFingerprint {
    param(
        [Parameter(Mandatory)] [string] $Package,
        [Parameter(Mandatory)] [string] $Directory
    )

    if (Test-Path -LiteralPath $Directory) {
        Remove-Item -LiteralPath $Directory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    & tar -xf $Package -C $Directory metadata.config contents.tar.gz
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect Hex package: $Package" }
    $contentsRoot = Join-Path $Directory 'contents'
    New-Item -ItemType Directory -Path $contentsRoot -Force | Out-Null
    & tar -xzf (Join-Path $Directory 'contents.tar.gz') -C $contentsRoot
    if ($LASTEXITCODE -ne 0) { throw "Could not expand Hex package contents: $Package" }

    $files = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $contentsRoot -File -Recurse | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($contentsRoot, $file.FullName).Replace('\', '/')
        $files[$relative] = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    }
    return [pscustomobject]@{
        metadata = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Directory 'metadata.config')).Hash.ToLowerInvariant()
        files = $files
    }
}

function Assert-SameHexPackage {
    param(
        [Parameter(Mandatory)] [string] $Expected,
        [Parameter(Mandatory)] [string] $Actual
    )

    $expectedFingerprint = Get-HexContentsFingerprint -Package $Expected -Directory (Join-Path $tempRoot 'expected')
    $actualFingerprint = Get-HexContentsFingerprint -Package $Actual -Directory (Join-Path $tempRoot 'actual')
    if ($expectedFingerprint.metadata -ne $actualFingerprint.metadata) {
        throw 'Published Hex metadata differs from the release artifact.'
    }
    $expectedJson = $expectedFingerprint.files | ConvertTo-Json -Compress
    $actualJson = $actualFingerprint.files | ConvertTo-Json -Compress
    if ($expectedJson -ne $actualJson) {
        throw 'Published Hex file names or expanded file hashes differ from the release artifact.'
    }
}

function Get-RemoteHexPackage {
    param([Parameter(Mandatory)] [string] $Destination)

    $uri = "https://repo.hex.pm/tarballs/beamtrace_core-$Version.tar"
    $response = Invoke-WebRequest -Uri $uri -OutFile $Destination -SkipHttpErrorCheck -PassThru
    return [int]$response.StatusCode
}

if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $remoteTarball = Join-Path $tempRoot "beamtrace_core-$Version-remote.tar"
    $status = Get-RemoteHexPackage -Destination $remoteTarball
    if ($status -eq 200) {
        Assert-SameHexPackage -Expected $localTarball -Actual $remoteTarball
        Write-Host "Hex beamtrace_core $Version already exists and is byte-for-byte equivalent after expansion; skipping publish."
        exit 0
    }
    if ($status -ne 404) {
        throw "Hex returned HTTP $status while checking beamtrace_core $Version."
    }
    if ([string]::IsNullOrWhiteSpace($env:HEXPM_API_KEY)) {
        throw 'HEXPM_API_KEY is required to publish a new Hex version.'
    }

    $coreRoot = Join-Path $repoRoot 'packages/beamtrace_core'
    Push-Location $coreRoot
    try {
        & gleam export hex-tarball
        if ($LASTEXITCODE -ne 0) { throw 'Could not reproduce the Hex tarball before publish.' }
        $rebuilt = Join-Path $coreRoot "build/beamtrace_core-$Version.tar"
        Assert-SameHexPackage -Expected $localTarball -Actual $rebuilt
        # Gleam deliberately requires this explicit acknowledgement for 0.x
        # releases even when --yes accepts the ordinary publish prompt.
        'I am not using semantic versioning' | & gleam publish --yes
        if ($LASTEXITCODE -ne 0) { throw "Hex publish failed for beamtrace_core $Version." }
    }
    finally {
        Pop-Location
    }

    $published = $false
    foreach ($attempt in 1..12) {
        if (Test-Path -LiteralPath $remoteTarball) {
            Remove-Item -LiteralPath $remoteTarball -Force
        }
        $status = Get-RemoteHexPackage -Destination $remoteTarball
        if ($status -eq 200) {
            $published = $true
            break
        }
        if ($status -ne 404) { throw "Hex returned HTTP $status after publish." }
        Start-Sleep -Seconds 5
    }
    if (-not $published) { throw "Hex did not expose beamtrace_core $Version after publish." }
    Assert-SameHexPackage -Expected $localTarball -Actual $remoteTarball
    Write-Host "Published and verified beamtrace_core $Version on Hex."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

exit 0
