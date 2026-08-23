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
        'Raw team relay capture is intentionally rejected',
        'Portable archives currently require Erlang/OTP 27–29 on the host'
    )
    'docs/roadmap.md' = @(
        '## Remaining integration work',
        'S3-compatible blob adapter',
        'relay CLI producer hookup',
        'bundled ERTS archives'
    )
    'docs/architecture.md' = @(
        'relay_frames.event_count',
        'SQLite WAL schema version 5',
        'Audit chains are verified when the team runtime opens',
        'Registered relay public keys are restored after a hub restart',
        'Credit is replenished only after durable acceptance',
        'Raw batches are rejected at the team relay boundary'
    )
    'docs/development.md' = @(
        './scripts/test-web-e2e.ps1',
        './scripts/test-hex-package.ps1',
        './scripts/test-oci.ps1 -Build',
        './scripts/test-release.ps1'
    )
    'CHANGELOG.md' = @(
        'PID-independent multi-run statistics',
        'GitHub OIDC artifact attestations'
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

$readme = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'README.md')
if ($readme.Contains('OIDC endpoint integration, durable SQLite/S3 team storage, and a persistent relay WebSocket remain roadmap work')) {
    throw 'README still reports implemented team boundaries as roadmap work.'
}
$roadmap = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs/roadmap.md')
if ($roadmap.Contains('durable shared annotations/audit records')) {
    throw 'Roadmap still reports durable annotations and audit records as future work.'
}

Write-Host 'Documentation acceptance passed.'
exit 0
