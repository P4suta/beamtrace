# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version,
    [Parameter(Mandatory)]
    [ValidatePattern('^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Image,
    [Parameter(Mandatory)]
    [ValidatePattern('^sha256:[0-9a-f]{64}$')]
    [string] $Digest
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project-version.ps1')
$projectVersion = Get-BeamTraceVersion -RepositoryRoot $repoRoot
if ($Version -ne $projectVersion) {
    throw "Published version $Version does not match project version $projectVersion."
}

$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.build'))
$tempRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot "published-consumer-$PID"))
if (-not $tempRoot.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe consumer test directory: $tempRoot"
}
if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $consumer = Join-Path $tempRoot 'beamtrace_release_consumer'
    & gleam new $consumer --name beamtrace_release_consumer --skip-github
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the clean Hex consumer project.' }
    $consumerToml = Join-Path $consumer 'gleam.toml'
    $toml = Get-Content -Raw -LiteralPath $consumerToml
    $toml = $toml -replace '(?m)^gleam_stdlib = .+$', "gleam_stdlib = `">= 0.70.0 and < 2.0.0`"`nbeamtrace_core = `"$Version`""
    $toml | Set-Content -LiteralPath $consumerToml -Encoding utf8NoBOM
    Copy-Item -LiteralPath (Join-Path $repoRoot 'fixtures/hex_consumer.gleam') `
        -Destination (Join-Path $consumer 'src/beamtrace_release_consumer.gleam')
    Push-Location $consumer
    try {
        $expected = 'codec=round-trip dag_boundaries=1 diagnostic_messages=1'
        $erlangOutput = (& gleam run --target erlang 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $erlangOutput.EndsWith($expected)) {
            throw "A clean Erlang consumer could not run beamtrace_core ${Version}:`n$erlangOutput"
        }
        $javascriptOutput = (& gleam run --target javascript --runtime nodejs 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $javascriptOutput.EndsWith($expected)) {
            throw "A clean JavaScript consumer could not run beamtrace_core ${Version}:`n$javascriptOutput"
        }
    }
    finally {
        Pop-Location
    }

    $docsAvailable = $false
    $docsUri = "https://hexdocs.pm/beamtrace_core/$Version/"
    foreach ($attempt in 1..18) {
        $response = Invoke-WebRequest -Uri $docsUri -Method Head -SkipHttpErrorCheck
        if ([int]$response.StatusCode -eq 200) {
            $docsAvailable = $true
            break
        }
        Start-Sleep -Seconds 10
    }
    if (-not $docsAvailable) { throw "Generated HexDocs did not become reachable: $docsUri" }

    $reference = "${Image}@${Digest}"
    & docker pull $reference
    if ($LASTEXITCODE -ne 0) { throw "Could not pull the published OCI digest: $reference" }
    $versionOutput = (& docker run --rm $reference version | Out-String)
    if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch ([regex]::Escape("beamtrace $Version"))) {
        throw 'Published OCI version smoke test failed.'
    }
    $doctor = (& docker run --rm $reference doctor | Out-String)
    if ($LASTEXITCODE -ne 0 -or $doctor -notmatch 'agent BEAM: valid' -or $doctor -notmatch 'web assets: valid') {
        throw 'Published OCI doctor smoke test failed.'
    }
    $uid = (& docker run --rm --entrypoint id $reference -u | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $uid -eq '0') {
        throw 'Published OCI image does not run as a non-root user.'
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Host "Published Hex, HexDocs, and OCI boundaries passed for $Version."
exit 0
