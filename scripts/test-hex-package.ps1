# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [switch] $ContainerBoundary
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project-version.ps1')
. (Join-Path $PSScriptRoot 'invoke-gleam-with-network-retry.ps1')
$projectVersion = Get-BeamTraceVersion -RepositoryRoot $repoRoot
$coreRoot = Join-Path $repoRoot 'packages/beamtrace_core'
$manifest = Join-Path $coreRoot 'gleam.toml'
$readme = Join-Path $coreRoot 'README.md'
$license = Join-Path $coreRoot 'LICENSE'

$manifestText = Get-Content -Raw -LiteralPath $manifest
foreach ($marker in @(
    'name = "beamtrace_core"',
    "version = `"$projectVersion`"",
    'licences = ["Apache-2.0", "MIT"]',
    'description = "Target-independent causal trace contracts and analysis for BeamTrace"',
    '[repository]',
    'type = "github"',
    'user = "P4suta"',
    'repo = "beamtrace"',
    'path = "packages/beamtrace_core"'
)) {
    if (-not $manifestText.Contains($marker)) {
        throw "Hex package metadata is missing: $marker"
    }
}
if (-not (Test-Path -LiteralPath $readme -PathType Leaf)) {
    throw 'The Hex package must include a package README.'
}
if (-not (Test-Path -LiteralPath $license -PathType Leaf)) {
    throw 'The Hex package must include its complete dual-licence text.'
}
$readmeText = Get-Content -Raw -LiteralPath $readme
foreach ($marker in @(
    'gleam add beamtrace_core',
    'https://hexdocs.pm/beamtrace_core/',
    'codec.encode_event',
    'dag.build',
    'diagnostics.hot_senders',
    'gleam run --target erlang',
    'gleam run --target javascript --runtime nodejs'
)) {
    if (-not $readmeText.Contains($marker)) {
        throw "The Hex README is missing: $marker"
    }
}
$licenseText = Get-Content -Raw -LiteralPath $license
foreach ($marker in @('Apache License', 'TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION', 'MIT License', 'Permission is hereby granted')) {
    if (-not $licenseText.Contains($marker)) {
        throw "The Hex package licence file is incomplete: $marker"
    }
}
foreach ($relative in @('LICENSES/Apache-2.0.txt', 'LICENSES/MIT.txt')) {
    $canonical = (Get-Content -Raw -LiteralPath (Join-Path $repoRoot $relative)).Trim()
    if (-not $licenseText.Contains($canonical)) {
        throw "The Hex package does not include the complete canonical licence: $relative"
    }
}

$tarball = Join-Path $coreRoot "build/beamtrace_core-$projectVersion.tar"
if ($ContainerBoundary) {
    $mount = "${repoRoot}:/src"
    $dockerArguments = @('run', '--rm')
    if (-not $IsWindows) {
        $hostUid = (& id -u | Out-String).Trim()
        $hostGid = (& id -g | Out-String).Trim()
        if ($hostUid -notmatch '^\d+$' -or $hostGid -notmatch '^\d+$') {
            throw 'Could not resolve the host UID/GID for the Hex container boundary.'
        }
        $dockerArguments += @('--user', "${hostUid}:${hostGid}")
    }
    $dockerArguments += @(
        '--volume', $mount,
        '--workdir', '/src/packages/beamtrace_core',
        'ghcr.io/gleam-lang/gleam:v1.18.1-erlang-alpine@sha256:7c82e4a284b7c05c26eac34db497ea0e63ce7cb04bd019d966d70338eb172b68',
        'gleam', 'export', 'hex-tarball'
    )
    & docker @dockerArguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
elseif (-not $IsWindows) {
    Push-Location $coreRoot
    try {
        $exportOutput = (& gleam export hex-tarball 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $exportOutput -match '(?m)^error:') {
            throw "Hex tarball export failed:`n$exportOutput"
        }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host 'Hex acceptance: Windows validates metadata; Linux CI performs the native export boundary.'
    exit 0
}

if (-not (Test-Path -LiteralPath $tarball -PathType Leaf)) {
    throw 'Hex tarball was not generated.'
}
$tempRoot = Join-Path $repoRoot '.build/hex-acceptance'
$resolvedBuild = [IO.Path]::GetFullPath((Join-Path $repoRoot '.build'))
$resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
if (-not $resolvedTemp.StartsWith($resolvedBuild, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe Hex inspection directory: $resolvedTemp"
}
if (Test-Path -LiteralPath $resolvedTemp) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
New-Item -ItemType Directory -Path $resolvedTemp -Force | Out-Null
try {
    & tar -xf $tarball -C $resolvedTemp contents.tar.gz
    if ($LASTEXITCODE -ne 0) { throw 'Could not extract the Hex package contents archive.' }
    $contents = @(& tar -tzf (Join-Path $resolvedTemp 'contents.tar.gz'))
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the Hex package contents.' }
    foreach ($required in @('gleam.toml', 'README.md', 'LICENSE', 'src/beamtrace/types.gleam')) {
        if ($required -notin $contents) { throw "Hex package is missing: $required" }
    }
    if ($contents | Where-Object { $_ -match '(^|/)(test|build)/' -or $_ -match '(^|/)(manifest\.toml|\.github)(/|$)' }) {
        throw 'Hex package includes test, build, lockfile, or repository-automation files.'
    }
    & tar -xf $tarball -C $resolvedTemp metadata.config
    if ($LASTEXITCODE -ne 0) { throw 'Could not extract Hex package metadata.' }
    $metadata = Get-Content -Raw -LiteralPath (Join-Path $resolvedTemp 'metadata.config')
    foreach ($marker in @('https://github.com/P4suta/beamtrace', 'Apache-2.0', 'MIT')) {
        if (-not $metadata.Contains($marker)) {
            throw "Hex tarball metadata is missing: $marker"
        }
    }

    # Compile the exact package payload that would be uploaded, not the
    # monorepo source tree. This catches missing files or package-boundary
    # assumptions before the immutable Hex version is published.
    $candidatePackage = Join-Path $resolvedTemp 'candidate-package'
    New-Item -ItemType Directory -Path $candidatePackage | Out-Null
    & tar -xzf (Join-Path $resolvedTemp 'contents.tar.gz') -C $candidatePackage
    if ($LASTEXITCODE -ne 0) { throw 'Could not extract the candidate Hex package payload.' }

    $consumer = Join-Path $resolvedTemp 'candidate-consumer'
    & gleam new $consumer --name beamtrace_hex_candidate_consumer --skip-github
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the candidate Hex consumer project.' }
    $consumerToml = Join-Path $consumer 'gleam.toml'
    $candidatePath = $candidatePackage.Replace('\', '/')
    $toml = Get-Content -Raw -LiteralPath $consumerToml
    $dependency = 'gleam_stdlib = ">= 0.70.0 and < 2.0.0"' + "`n" +
        "beamtrace_core = { path = `"$candidatePath`" }"
    $toml = $toml -replace '(?m)^gleam_stdlib = .+$', $dependency
    $toml | Set-Content -LiteralPath $consumerToml -Encoding utf8NoBOM
    Copy-Item -LiteralPath (Join-Path $repoRoot 'fixtures/hex_consumer.gleam') `
        -Destination (Join-Path $consumer 'src/beamtrace_hex_candidate_consumer.gleam')

    Push-Location $consumer
    try {
        $expected = 'codec=round-trip dag_boundaries=1 diagnostic_messages=1'
        $erlangRun = Invoke-GleamWithNetworkRetry -Arguments @('run', '--target', 'erlang')
        $erlangOutput = $erlangRun.Output.Trim()
        if ($erlangRun.ExitCode -ne 0 -or -not $erlangOutput.EndsWith($expected)) {
            throw "Candidate Hex payload failed in an isolated Erlang consumer:`n$erlangOutput"
        }
        $javascriptRun = Invoke-GleamWithNetworkRetry -Arguments @(
            'run', '--target', 'javascript', '--runtime', 'nodejs'
        )
        $javascriptOutput = $javascriptRun.Output.Trim()
        if ($javascriptRun.ExitCode -ne 0 -or -not $javascriptOutput.EndsWith($expected)) {
            throw "Candidate Hex payload failed in an isolated JavaScript consumer:`n$javascriptOutput"
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if (Test-Path -LiteralPath $resolvedTemp) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

Write-Host 'Hex package acceptance passed.'
exit 0
