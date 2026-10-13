# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$expectations = [ordered]@{
    'README.md' = @(
        '## Install',
        '## 60-second demo',
        '### Gleam',
        '### Elixir',
        '### Erlang',
        '`/api/v2/openapi.json`',
        'mise run test'
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
    'docs/reading-results.md' = @(
        'Observation end',
        'Delivery verification and issues',
        'Exact and Inferred',
        'First divergence'
    )
    'docs/api-reference.md' = @(
        '/api/v2/openapi.json',
        'code',
        'message',
        'hint',
        'v0.4 removal headers'
    )
    'docs/development.md' = @(
        'mise run beamtrace -- demo',
        'mise run test:all',
        './scripts/test-web-e2e.ps1',
        './scripts/test-hex-package.ps1',
        './scripts/test-s3-dogfood.ps1',
        './scripts/test-oci.ps1 -Build',
        './scripts/test-release.ps1'
    )
    'docs/cli-reference.md' = @(
        '## Exit codes',
        '| 130 |',
        '| 143 |',
        '## Error codes',
        'schemas/beamtrace-cli-v1/envelope.schema.json',
        '--capture-window'
    )
    'docs/aql-reference.md' = @(
        '## Grammar',
        '## Fields',
        '## Evaluation rules',
        'ns/us/ms/s'
    )
    'docs/getting-started.md' = @(
        'beamtrace demo --no-ui --json',
        'mise run beamtrace'
    )
    'docs/troubleshooting.md' = @(
        'beamtrace help errors',
        'E_AGENT_BEAM_UNAVAILABLE',
        'E_COMMAND_NOT_FOUND',
        'E_CAPTURE_ARM_TIMEOUT',
        'E_ARCHIVE_NOT_FOUND',
        'beamtrace attach <node> --web',
        '--capture-window'
    )
    'docs/record-elixir.md' = @('--acknowledge-seq-trace-reset')
    '.mise.toml' = @(
        '[tasks."test:all"]',
        '[tasks.beamtrace]'
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
$troubleshooting = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs/troubleshooting.md')
foreach ($stale in @('with MFA search', 'use Live for bounded')) {
    if ($troubleshooting.Contains($stale)) {
        throw "docs/troubleshooting.md still advertises a feature the CLI does not have: $stale"
    }
}

. (Join-Path $PSScriptRoot 'project-version.ps1')
$projectVersion = Get-BeamTraceVersion -RepositoryRoot $repoRoot
if (-not $readme.Contains("VERSION=$projectVersion # x-release-please-version")) {
    throw "README.md install example must use VERSION=$projectVersion with the release-please marker."
}

$adrIndex = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs/adr/README.md')
foreach ($adr in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs/adr') -Filter '0*.md') {
    if (-not $adrIndex.Contains("($($adr.Name))")) {
        throw "docs/adr/README.md does not index $($adr.Name)"
    }
    $body = Get-Content -Raw -LiteralPath $adr.FullName
    foreach ($section in @('Status:', '## Context', '## Decision', '## Consequences')) {
        if (-not $body.Contains($section)) {
            throw "$($adr.Name) lacks the MADR section $section"
        }
    }
}

$roadmap = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs/roadmap.md')
if ($roadmap.Contains('durable shared annotations/audit records')) {
    throw 'Roadmap still reports durable annotations and audit records as future work.'
}

& node (Join-Path $PSScriptRoot 'check-env-docs.mjs')
if ($LASTEXITCODE -ne 0) {
    throw 'docs/environment-variables.md is out of sync with the sources.'
}

Write-Host 'Documentation acceptance passed.'
exit 0
