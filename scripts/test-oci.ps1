# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [switch] $Build
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project-version.ps1')
$projectVersion = Get-BeamTraceVersion -RepositoryRoot $repoRoot
$dockerfile = Join-Path $repoRoot 'packaging/Dockerfile'
if (-not (Test-Path -LiteralPath $dockerfile -PathType Leaf)) {
    throw 'OCI Dockerfile is missing.'
}
$source = Get-Content -Raw -LiteralPath $dockerfile
$baseImages = [regex]::Matches($source, '(?m)^FROM\s+([^\s]+)')
foreach ($baseImage in $baseImages) {
    $reference = $baseImage.Groups[1].Value
    if ($reference -notmatch '@sha256:[0-9a-f]{64}$') {
        throw "OCI base image is not pinned to a SHA-256 digest: $reference"
    }
}
foreach ($marker in @(
    'ghcr.io/gleam-lang/gleam:v1.18.1-erlang-alpine',
    'RUN apk add --no-cache build-base=0.5-r3 git=2.52.0-r0',
    'FROM erlang:29-alpine',
    'RUN apk add --no-cache ca-certificates=20260611-r0',
    'gleam export erlang-shipment',
    'HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3',
    'http://127.0.0.1:4040/api/v1/ready',
    'USER 10001:10001',
    'ENTRYPOINT ["/bin/sh", "/opt/beamtrace/runtime/entrypoint.sh", "run"]',
    'CMD ["serve"]'
)) {
    if (-not $source.Contains($marker)) { throw "OCI Dockerfile missing: $marker" }
}

if (-not $Build) {
    Write-Host 'OCI acceptance: static contract passed (use -Build for image boundary)'
    exit 0
}

$tag = "beamtrace-acceptance:$PID"
$containerName = "beamtrace-acceptance-$PID"
$containerStarted = $false
try {
    & docker build --file $dockerfile --tag $tag $repoRoot
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $version = (& docker run --rm $tag version | Out-String)
    if ($LASTEXITCODE -ne 0 -or $version -notmatch ([regex]::Escape("beamtrace $projectVersion"))) {
        throw 'OCI version smoke test failed.'
    }
    $doctor = (& docker run --rm $tag doctor | Out-String)
    if ($LASTEXITCODE -ne 0 -or $doctor -notmatch 'agent BEAM: valid' -or $doctor -notmatch 'web assets: valid') {
        throw 'OCI doctor smoke test failed.'
    }
    $uid = (& docker run --rm --entrypoint id $tag -u | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $uid -eq '0') {
        throw 'OCI image must run as a non-root user.'
    }

    $containerId = (& docker run --detach --rm --name $containerName $tag | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($containerId)) {
        throw 'OCI server container did not start.'
    }
    $containerStarted = $true
    $health = ''
    for ($attempt = 1; $attempt -le 40; $attempt++) {
        $health = (& docker inspect --format '{{.State.Health.Status}}' $containerName | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect OCI server health.' }
        if ($health -eq 'healthy') { break }
        if ($health -eq 'unhealthy') { break }
        Start-Sleep -Milliseconds 500
    }
    if ($health -ne 'healthy') {
        $logs = (& docker logs $containerName 2>&1 | Out-String).Trim()
        throw "OCI /api/v1/ready healthcheck did not become healthy (status: $health): $logs"
    }
}
finally {
    if ($containerStarted) {
        & docker rm --force $containerName 2>$null | Out-Null
    }
    & docker image rm --force $tag 2>$null | Out-Null
}

exit 0
