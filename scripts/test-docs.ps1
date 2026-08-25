# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$expectations = [ordered]@{
    'README.md' = @(
        'SQLite WAL metadata',
        'durable annotations and hash-chained audit history',
        'Admin-only `/api/v1/audit`',
        'outbound relay WebSocket',
        'separately authorized bounded raw capture',
        'Native release archives include ERTS',
        'Merging its release PR is the publication approval'
    )
    'docs/roadmap.md' = @(
        '## Post-alpha release operations',
        'HTTPS S3-compatible SigV4 blobs',
        'relay producer capture',
        'bundled ERTS'
    )
    'docs/architecture.md' = @(
        'session event counts',
        'SQLite WAL schema version 9',
        'Audit chains are verified when the team runtime opens',
        'Registered relay public keys are restored after a hub restart',
        'Credit is replenished only after durable acceptance',
        'Raw batches additionally require a relay-bound one-time grant'
    )
    'docs/development.md' = @(
        './scripts/test-web-e2e.ps1',
        './scripts/test-hex-package.ps1',
        './scripts/test-s3-dogfood.ps1',
        './scripts/test-oci.ps1 -Build',
        './scripts/test-release.ps1'
    )
    'docs/releasing.md' = @(
        'release-automation',
        'RELEASE_PLEASE_APP_CLIENT_ID',
        'HEXPM_API_KEY',
        'Merging a release pull request is the sole human approval',
        'The workflow never uses Hex `--replace`'
    )
}

foreach ($entry in $expectations.GetEnumerator()) {
    $source = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $entry.Key)
    foreach ($marker in $entry.Value) {
        if (-not $source.Contains($marker)) {
            throw "$($entry.Key) is missing documentation marker: $marker"
        }
    }
}

$releaseManifest = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.release-please-manifest.json') | ConvertFrom-Json
$changelog = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'CHANGELOG.md')
if (@($releaseManifest.PSObject.Properties).Count -eq 0 -and $changelog.Length -ne 0) {
    throw 'The changelog must remain empty in the release-please bootstrap state.'
}

$readme = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'README.md')
if ($readme.Contains('OIDC endpoint integration, durable SQLite/S3 team storage, and a persistent relay WebSocket remain roadmap work')) {
    throw 'README still reports implemented team boundaries as roadmap work.'
}
if ($readme.Contains('Raw team relay capture is intentionally rejected') -or $readme.Contains('bundled ERTS archives are still pending')) {
    throw 'README still reports completed raw-capture or bundled-runtime work as pending.'
}
$roadmap = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs/roadmap.md')
if ($roadmap.Contains('durable shared annotations/audit records')) {
    throw 'Roadmap still reports durable annotations and audit records as future work.'
}

Write-Host 'Documentation acceptance passed.'
exit 0
