# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$workflow = Join-Path $repoRoot '.github/workflows/release.yml'
$versionCheck = Join-Path $PSScriptRoot 'assert-release-version.ps1'

if (-not (Test-Path -LiteralPath $workflow -PathType Leaf)) {
    throw 'The release workflow is missing.'
}
if (-not (Test-Path -LiteralPath $versionCheck -PathType Leaf)) {
    throw 'The release version guard is missing.'
}

$runtimeManifest = Join-Path $repoRoot 'packages/beamtrace_runtime/gleam.toml'
$versionMatch = Select-String -LiteralPath $runtimeManifest -Pattern '^version = "([^"]+)"$' | Select-Object -First 1
if ($null -eq $versionMatch) { throw 'The runtime package version is missing.' }
$projectTag = 'v' + $versionMatch.Matches[0].Groups[1].Value
& pwsh -NoProfile -File $versionCheck -Tag $projectTag
if ($LASTEXITCODE -ne 0) { throw 'The release version guard rejected the project version.' }
& pwsh -NoProfile -File $versionCheck -Tag v9.9.9 *> $null
if ($LASTEXITCODE -eq 0) { throw 'The release version guard accepted a mismatched tag.' }

$source = Get-Content -Raw -LiteralPath $workflow
foreach ($marker in @(
    "tags: ['v*']",
    'runner: ubuntu-latest',
    'runner: ubuntu-24.04-arm',
    'runner: windows-latest',
    'runner: windows-11-arm',
    'runner: macos-15-intel',
    'runner: macos-15',
    './scripts/assert-release-version.ps1 -Tag',
    './scripts/package.ps1 -SkipTests',
    './scripts/test-hex-package.ps1',
    './scripts/generate-distribution-metadata.ps1',
    'id-token: write',
    'attestations: write',
    'packages: write',
    'actions/attest@',
    'docker push',
    'gh release create'
)) {
    if (-not $source.Contains($marker)) { throw "Release workflow is missing: $marker" }
}

$uses = [regex]::Matches($source, '(?m)^\s*- uses:\s*([^\s#]+)')
foreach ($match in $uses) {
    $action = $match.Groups[1].Value
    if ($action -notmatch '@[0-9a-f]{40}$') {
        throw "Release action is not pinned to a full commit SHA: $action"
    }
}

$ci = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github/workflows/ci.yml')
if (-not $ci.Contains('./scripts/test-oci.ps1 -Build')) {
    throw 'CI does not exercise the real OCI image boundary.'
}
if (-not $ci.Contains('./scripts/test-s3-dogfood.ps1')) {
    throw 'CI does not exercise the real S3-compatible TLS boundary.'
}

Write-Host 'Release acceptance passed.'
exit 0
