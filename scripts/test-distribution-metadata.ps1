# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$output = Join-Path $repoRoot ".build/distribution-metadata-$PID"
$checksums = Join-Path $output 'release-checksums.json'
New-Item -ItemType Directory -Path $output -Force | Out-Null
try {
    [ordered]@{
        'beamtrace-0.1.0-macos-arm64.zip' = ('a' * 64)
        'beamtrace-0.1.0-macos-x64.zip' = ('b' * 64)
        'beamtrace-0.1.0-linux-arm64.zip' = ('c' * 64)
        'beamtrace-0.1.0-linux-x64.zip' = ('d' * 64)
        'beamtrace-0.1.0-windows-arm64.zip' = ('e' * 64)
        'beamtrace-0.1.0-windows-x64.zip' = ('f' * 64)
    } | ConvertTo-Json | Set-Content -LiteralPath $checksums -Encoding utf8NoBOM

    & (Join-Path $PSScriptRoot 'generate-distribution-metadata.ps1') `
        -Version '0.1.0' `
        -BaseUrl 'https://downloads.example.test/beamtrace/v0.1.0' `
        -Homepage 'https://source.example.test/beamtrace' `
        -ChecksumsPath $checksums `
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
        'version "0.1.0"',
        'homepage "https://source.example.test/beamtrace"',
        'beamtrace-0.1.0-macos-arm64.zip',
        ('sha256 "' + ('a' * 64) + '"'),
        'beamtrace-0.1.0-linux-x64.zip',
        ('sha256 "' + ('d' * 64) + '"'),
        'chmod 0755, libexec/"bin/beamtrace"',
        'bin.install_symlink libexec/"bin/beamtrace"'
    )) {
        if (-not $formula.Contains($marker)) { throw "Formula missing: $marker" }
    }
    $scoop = Get-Content -Raw -LiteralPath $scoopPath | ConvertFrom-Json
    if ($scoop.version -ne '0.1.0' -or $scoop.homepage -ne 'https://source.example.test/beamtrace' -or $scoop.architecture.'64bit'.hash -ne ('f' * 64) -or $scoop.architecture.arm64.hash -ne ('e' * 64)) {
        throw 'Scoop manifest has incorrect version or hashes.'
    }
    if ($scoop.architecture.'64bit'.url -notmatch '^https://' -or $scoop.bin[0][1] -ne 'beamtrace') {
        throw 'Scoop manifest must use HTTPS and install the beamtrace shim.'
    }
}
finally {
    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Recurse -Force
    }
}

exit 0
