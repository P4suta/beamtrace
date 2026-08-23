# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project-version.ps1')
$version = Get-BeamTraceVersion -RepositoryRoot $repoRoot
$output = Join-Path $repoRoot ".build/distribution-metadata-$PID"
$checksums = Join-Path $output 'release-checksums.json'
New-Item -ItemType Directory -Path $output -Force | Out-Null
try {
    $expectedChecksums = [ordered]@{}
    foreach ($target in @(
        'macos-arm64',
        'macos-x64',
        'linux-arm64',
        'linux-x64',
        'windows-arm64',
        'windows-x64'
    )) {
        $name = "beamtrace-$version-$target.zip"
        $archive = Join-Path $output $name
        "fixture:$name" | Set-Content -LiteralPath $archive -NoNewline -Encoding utf8NoBOM
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
        $expectedChecksums[$name] = $hash
        "$hash  $name" | Set-Content -LiteralPath "$archive.sha256" -Encoding ascii
    }

    & (Join-Path $PSScriptRoot 'build-distribution-metadata.ps1') `
        -BaseUrl "https://downloads.example.test/beamtrace/v$version" `
        -Homepage 'https://source.example.test/beamtrace' `
        -OutputDirectory $output
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $formulaPath = Join-Path $output 'beamtrace.rb'
    $scoopPath = Join-Path $output 'beamtrace.json'
    if (-not (Test-Path -LiteralPath $formulaPath -PathType Leaf)) {
        throw 'Homebrew formula was not generated.'
    }
    if (-not (Test-Path -LiteralPath $scoopPath -PathType Leaf)) {
        throw 'Scoop manifest was not generated.'
    }
    $formula = Get-Content -Raw -LiteralPath $formulaPath
    foreach ($marker in @(
        'class BeamTrace < Formula',
        "version `"$version`"",
        'homepage "https://source.example.test/beamtrace"',
        "beamtrace-$version-macos-arm64.zip",
        ('sha256 "' + $expectedChecksums["beamtrace-$version-macos-arm64.zip"] + '"'),
        "beamtrace-$version-linux-x64.zip",
        ('sha256 "' + $expectedChecksums["beamtrace-$version-linux-x64.zip"] + '"'),
        'chmod 0755, libexec/"bin/beamtrace"',
        'bin.install_symlink libexec/"bin/beamtrace"'
    )) {
        if (-not $formula.Contains($marker)) { throw "Formula missing: $marker" }
    }
    $scoop = Get-Content -Raw -LiteralPath $scoopPath | ConvertFrom-Json
    if (
        $scoop.version -ne $version -or
        $scoop.homepage -ne 'https://source.example.test/beamtrace' -or
        $scoop.architecture.'64bit'.hash -ne $expectedChecksums["beamtrace-$version-windows-x64.zip"] -or
        $scoop.architecture.arm64.hash -ne $expectedChecksums["beamtrace-$version-windows-arm64.zip"]
    ) {
        throw 'Scoop manifest has incorrect version or hashes.'
    }
    if ($scoop.architecture.'64bit'.url -notmatch '^https://' -or $scoop.bin[0][1] -ne 'beamtrace') {
        throw 'Scoop manifest must use HTTPS and install the beamtrace shim.'
    }

    $inventory = Get-Content -Raw -LiteralPath $checksums | ConvertFrom-Json -AsHashtable
    if ($inventory.Count -ne 6) { throw 'Checksum inventory must contain exactly six native archives.' }
    foreach ($entry in $expectedChecksums.GetEnumerator()) {
        if ($inventory[$entry.Key] -ne $entry.Value) {
            throw "Checksum inventory differs from the built archive: $($entry.Key)"
        }
    }

    $mismatchedArchive = "beamtrace-$version-macos-arm64.zip"
    ('0' * 64) + "  $mismatchedArchive" |
        Set-Content -LiteralPath (Join-Path $output "$mismatchedArchive.sha256") -Encoding ascii
    $rejected = $false
    try {
        & (Join-Path $PSScriptRoot 'build-distribution-metadata.ps1') `
            -BaseUrl "https://downloads.example.test/beamtrace/v$version" `
            -Homepage 'https://source.example.test/beamtrace' `
            -OutputDirectory $output *> $null
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) { throw 'Distribution metadata accepted a mismatched checksum sidecar.' }
}
finally {
    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Recurse -Force
    }
}

exit 0
