# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$schemaRoot = Join-Path $repoRoot 'schemas/beamtrace-v2'
$fixtureRoot = Join-Path $repoRoot 'fixtures/format-v2'

$documents = @(
    @{ Schema = 'manifest.schema.json'; Instances = @('valid/manifest.json') },
    @{ Schema = 'event.schema.json'; Instances = @('valid/event.json', 'valid/inferred-event.json') },
    @{ Schema = 'graph-segment.schema.json'; Instances = @('valid/graph-segment.json') },
    @{ Schema = 'clocks.schema.json'; Instances = @('valid/clocks.json') },
    @{ Schema = 'index.schema.json'; Instances = @('valid/index.json') },
    @{ Schema = 'annotations.schema.json'; Instances = @('valid/annotations.json') },
    @{ Schema = 'checksums.schema.json'; Instances = @('valid/checksums.json') }
)

foreach ($schema in Get-ChildItem -LiteralPath $schemaRoot -Filter '*.json') {
    $null = Get-Content -Raw -LiteralPath $schema.FullName | ConvertFrom-Json -Depth 100
}
foreach ($fixture in Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.json' -Recurse) {
    $null = Get-Content -Raw -LiteralPath $fixture.FullName | ConvertFrom-Json -Depth 100
}

foreach ($document in $documents) {
    $schema = Join-Path $schemaRoot $document.Schema
    foreach ($instance in $document.Instances) {
        $path = Join-Path $fixtureRoot $instance
        if (-not (Test-Json -LiteralPath $path -SchemaFile $schema)) {
            throw "$instance does not conform to $($document.Schema)."
        }
    }
}

Push-Location (Join-Path $repoRoot 'packages/beamtrace_core')
try {
    & gleam check
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
}

& escript (Join-Path $PSScriptRoot 'format-conformance.escript') $repoRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host 'BeamTrace format v2 schema and golden-corpus conformance passed.'
exit 0
