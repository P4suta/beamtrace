# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [switch] $Build
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
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
    'RUN apk add --no-cache build-base git',
    'FROM erlang:29-alpine',
    'gleam export erlang-shipment',
    'USER beamtrace',
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
try {
    & docker build --file $dockerfile --tag $tag $repoRoot
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $version = (& docker run --rm $tag version | Out-String)
    if ($LASTEXITCODE -ne 0 -or $version -notmatch 'beamtrace 0\.1\.0') {
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
}
finally {
    & docker image rm --force $tag 2>$null | Out-Null
}

exit 0
