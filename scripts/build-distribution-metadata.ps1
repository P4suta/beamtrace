# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string] $BaseUrl,
    [ValidatePattern('^https://')]
    [string] $Homepage = 'https://github.com/P4suta/beamtrace',
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project-version.ps1')
$version = Get-BeamTraceVersion -RepositoryRoot $repoRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'dist'
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null

$archives = @(Get-ChildItem -LiteralPath $output -Filter "beamtrace-$version-*.zip" -File)
if ($archives.Count -ne 6) {
    throw "Expected six native archives for $version, found $($archives.Count)."
}

$checksums = [ordered]@{}
foreach ($archive in $archives | Sort-Object Name) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive.FullName).Hash.ToLowerInvariant()
    $checksums[$archive.Name] = $hash
    $sidecar = "$($archive.FullName).sha256"
    if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) {
        throw "Archive checksum sidecar is missing: $($archive.Name).sha256"
    }
    $sidecarText = (Get-Content -Raw -LiteralPath $sidecar).Trim()
    if ($sidecarText -ne "$hash  $($archive.Name)") {
        throw "Archive checksum sidecar does not match: $($archive.Name).sha256"
    }
}

$inventory = Join-Path $output 'release-checksums.json'
$checksums | ConvertTo-Json | Set-Content -LiteralPath $inventory -Encoding utf8NoBOM
& (Join-Path $PSScriptRoot 'generate-distribution-metadata.ps1') `
    -Version $version `
    -BaseUrl $BaseUrl.TrimEnd('/') `
    -Homepage $Homepage `
    -ChecksumsPath $inventory `
    -OutputDirectory $output
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

foreach ($relative in @('release-checksums.json', 'beamtrace.rb', 'beamtrace.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $output $relative) -PathType Leaf)) {
        throw "Distribution metadata was not generated: $relative"
    }
}

Write-Host "Distribution metadata for $version passed."
exit 0
