# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [switch] $SkipTests,
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'enable-msvc.ps1')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'dist'
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryRoot = [IO.Path]::GetFullPath($repoRoot)
if (-not $outputRoot.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Package output directory must remain inside the repository: $outputRoot"
}

if (-not $SkipTests) {
    & (Join-Path $PSScriptRoot 'test-all.ps1')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

& (Join-Path $PSScriptRoot 'ensure-rebar3.ps1')
$env:PATH = "$PSScriptRoot$([IO.Path]::PathSeparator)$env:PATH"
$env:REBAR_CACHE_DIR = Join-Path $repoRoot '.cache/rebar3'
& (Join-Path $PSScriptRoot 'build-web.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$agentBeam = & (Join-Path $PSScriptRoot 'build-agent.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

. (Join-Path $PSScriptRoot 'project-version.ps1')
$version = Get-BeamTraceVersion -RepositoryRoot $repoRoot

if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { $platform = 'windows' }
elseif ($IsMacOS) { $platform = 'macos' }
else { $platform = 'linux' }
$architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$packageName = "beamtrace-$version-$platform-$architecture"
$stageParent = Join-Path $repoRoot '.build/package'
$stageRoot = Join-Path $stageParent $packageName
$resolvedStage = [IO.Path]::GetFullPath($stageRoot)
$resolvedStageParent = [IO.Path]::GetFullPath($stageParent)
if (-not $resolvedStage.StartsWith($resolvedStageParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe package staging directory: $resolvedStage"
}
if (Test-Path -LiteralPath $resolvedStage) {
    Remove-Item -LiteralPath $resolvedStage -Recurse -Force
}

$directories = @(
    'bin',
    'lib',
    'lib/native/esqlite/ebin',
    'lib/native/esqlite/priv',
    'share/beamtrace/web',
    'docs',
    'LICENSES'
)
foreach ($relative in $directories) {
    New-Item -ItemType Directory -Path (Join-Path $resolvedStage $relative) -Force | Out-Null
}

$runtimeDirectory = Join-Path $repoRoot 'packages/beamtrace_runtime'
Push-Location $runtimeDirectory
try {
    & gleam export escript
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
}

$otpRoot = (& erl -noshell -eval 'io:format("~ts", [code:root_dir()]), halt().' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $otpRoot -PathType Container)) {
    throw 'Could not resolve the Erlang/OTP runtime root.'
}
$otpRelease = (& erl -noshell -eval 'io:format("~ts", [erlang:system_info(otp_release)]), halt().' | Out-String).Trim()
$ertsVersion = (& erl -noshell -eval 'io:format("~ts", [erlang:system_info(version)]), halt().' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $otpRelease -notmatch '^(27|28|29)$' -or [string]::IsNullOrWhiteSpace($ertsVersion)) {
    throw "Packaging requires Erlang/OTP 27-29, found OTP '$otpRelease' and ERTS '$ertsVersion'."
}
$otpVersionSource = Join-Path $otpRoot "releases/$otpRelease/OTP_VERSION"
$otpVersion = if (Test-Path -LiteralPath $otpVersionSource -PathType Leaf) {
    (Get-Content -Raw -LiteralPath $otpVersionSource).Trim()
}
else {
    $otpRelease
}
$runtimeRoot = Join-Path $resolvedStage 'runtime'
$ertsSource = Join-Path $otpRoot "erts-$ertsVersion"
$ertsDestination = Join-Path $runtimeRoot "erts-$ertsVersion"
$ertsBinSource = Join-Path $ertsSource 'bin'
$ertsBinDestination = Join-Path $ertsDestination 'bin'
if (-not (Test-Path -LiteralPath $ertsBinSource -PathType Container)) {
    throw "ERTS executable directory is missing: $ertsBinSource"
}
New-Item -ItemType Directory -Path $ertsBinDestination -Force | Out-Null
$excludedErtsDevelopmentCommands = @(
    'ct_run',
    'dialyzer',
    'erlc',
    'typer',
    'yielding_c_fun'
)
foreach ($entry in Get-ChildItem -LiteralPath $ertsBinSource -Force) {
    if ($entry.Extension -eq '.pdb' -or $entry.Name -match '\.debug\.') { continue }
    if ($entry.BaseName -in $excludedErtsDevelopmentCommands) { continue }
    Copy-Item -LiteralPath $entry.FullName -Destination $ertsBinDestination -Recurse -Force
}

$otpApplications = @('erts', 'kernel', 'stdlib', 'crypto', 'asn1', 'public_key', 'ssl', 'inets')
foreach ($application in $otpApplications) {
    $matches = @(Get-ChildItem -LiteralPath (Join-Path $otpRoot 'lib') -Directory -Filter "$application-*")
    if ($matches.Count -ne 1) {
        throw "Expected exactly one OTP application directory for $application, found $($matches.Count)."
    }
    $applicationDestination = Join-Path $runtimeRoot "lib/$($matches[0].Name)"
    New-Item -ItemType Directory -Path $applicationDestination -Force | Out-Null
    foreach ($runtimeDirectoryName in @('ebin', 'priv')) {
        $source = Join-Path $matches[0].FullName $runtimeDirectoryName
        if (Test-Path -LiteralPath $source -PathType Container) {
            Copy-Item -LiteralPath $source -Destination $applicationDestination -Recurse -Force
        }
    }
}

$releaseSource = Join-Path $otpRoot "releases/$otpRelease"
if (Test-Path -LiteralPath $releaseSource -PathType Container) {
    $releaseDestination = Join-Path $runtimeRoot "releases/$otpRelease"
    New-Item -ItemType Directory -Path (Split-Path -Parent $releaseDestination) -Force | Out-Null
    Copy-Item -LiteralPath $releaseSource -Destination $releaseDestination -Recurse -Force
}
$runtimeBin = Join-Path $runtimeRoot 'bin'
New-Item -ItemType Directory -Path $runtimeBin -Force | Out-Null
foreach ($bootFile in Get-ChildItem -LiteralPath (Join-Path $otpRoot 'bin') -File -Filter '*.boot') {
    Copy-Item -LiteralPath $bootFile.FullName -Destination $runtimeBin -Force
}
$otpVersion | Set-Content -LiteralPath (Join-Path $runtimeRoot 'OTP_VERSION') -Encoding ascii

Copy-Item -LiteralPath (Join-Path $runtimeDirectory 'beamtrace_runtime') -Destination (Join-Path $resolvedStage 'lib/beamtrace.escript')
Copy-Item -LiteralPath $agentBeam -Destination (Join-Path $resolvedStage 'lib/beamtrace_agent.beam')
$esqliteRoot = Join-Path $runtimeDirectory 'build/prod/erlang/esqlite'
$esqliteApp = Join-Path $esqliteRoot 'ebin/esqlite.app'
$esqliteNif = Get-ChildItem -LiteralPath (Join-Path $esqliteRoot 'priv') -File | Where-Object {
    $_.BaseName -eq 'esqlite3_nif' -and $_.Extension -in @('.dll', '.so', '.dylib')
} | Select-Object -First 1
if (-not (Test-Path -LiteralPath $esqliteApp -PathType Leaf) -or $null -eq $esqliteNif) {
    throw 'The platform SQLite NIF was not produced.'
}
Copy-Item -LiteralPath $esqliteApp -Destination (Join-Path $resolvedStage 'lib/native/esqlite/ebin/esqlite.app')
Copy-Item -LiteralPath $esqliteNif.FullName -Destination (Join-Path $resolvedStage "lib/native/esqlite/priv/$($esqliteNif.Name)")
Copy-Item -LiteralPath (Join-Path $repoRoot 'packaging/beamtrace') -Destination (Join-Path $resolvedStage 'bin/beamtrace')
Copy-Item -LiteralPath (Join-Path $repoRoot 'packaging/beamtrace.ps1') -Destination (Join-Path $resolvedStage 'bin/beamtrace.ps1')
Copy-Item -Path (Join-Path $repoRoot 'packages/beamtrace_web/dist/*') -Destination (Join-Path $resolvedStage 'share/beamtrace/web') -Recurse
Copy-Item -Path (Join-Path $repoRoot 'LICENSES/*') -Destination (Join-Path $resolvedStage 'LICENSES')
Copy-Item -Path (Join-Path $repoRoot 'docs/*') -Destination (Join-Path $resolvedStage 'docs') -Recurse
foreach ($file in @('README.md', 'CHANGELOG.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md', 'CONTRIBUTING.md', 'REUSE.toml')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination $resolvedStage
}

$inventory = @{}
foreach ($packageDirectory in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'packages') -Directory | Sort-Object FullName) {
    $manifestPath = Join-Path $packageDirectory.FullName 'manifest.toml'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }

    $content = Get-Content -Raw -LiteralPath $manifestPath
    foreach ($match in [regex]::Matches($content, '\{ name = "([^"]+)", version = "([^"]+)"[^\r\n]*source = "([^"]+)"')) {
        $name = $match.Groups[1].Value
        $lockedVersion = $match.Groups[2].Value
        $source = $match.Groups[3].Value
        $downloadLocation = if ($source -eq 'hex') { "https://hex.pm/packages/$name" } else { 'NOASSERTION' }
        if ($inventory.ContainsKey($name)) {
            $existing = $inventory[$name]
            if (
                $existing.versionInfo -ne $lockedVersion -or
                $existing.downloadLocation -ne $downloadLocation
            ) {
                throw "Immediate package manifests disagree on the locked source for ${name}."
            }
            continue
        }
        $inventory[$name] = [pscustomobject]@{
            SPDXID = 'SPDXRef-Package-' + ($name -replace '[^A-Za-z0-9.-]', '-')
            name = $name
            versionInfo = $lockedVersion
            downloadLocation = $downloadLocation
            filesAnalyzed = $false
            licenseConcluded = 'NOASSERTION'
            licenseDeclared = 'NOASSERTION'
        }
    }
}
foreach ($name in @('beamtrace_core', 'beamtrace_runtime', 'beamtrace_web', 'beamtrace_tui', 'beamtrace_agent')) {
    $inventory[$name] = [pscustomobject]@{
        SPDXID = 'SPDXRef-Package-' + $name
        name = $name
        versionInfo = $version
        downloadLocation = 'NOASSERTION'
        filesAnalyzed = $false
        licenseConcluded = 'Apache-2.0 OR MIT'
        licenseDeclared = 'Apache-2.0 OR MIT'
    }
}
$inventory['erlang_otp'] = [pscustomobject]@{
    SPDXID = 'SPDXRef-Package-erlang-otp'
    name = 'erlang_otp'
    versionInfo = $otpVersion
    downloadLocation = 'https://github.com/erlang/otp'
    filesAnalyzed = $false
    licenseConcluded = 'Apache-2.0'
    licenseDeclared = 'Apache-2.0'
}
$created = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$sbom = [ordered]@{
    spdxVersion = 'SPDX-2.3'
    dataLicense = 'CC0-1.0'
    SPDXID = 'SPDXRef-DOCUMENT'
    name = $packageName
    documentNamespace = "https://beamtrace.dev/spdx/$packageName/$([guid]::NewGuid())"
    creationInfo = [ordered]@{
        created = $created
        creators = @('Tool: beamtrace-package.ps1')
    }
    packages = @($inventory.Values | Sort-Object name)
}
$sbom | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resolvedStage 'SBOM.spdx.json') -Encoding utf8NoBOM

$checksumLines = foreach ($file in Get-ChildItem -LiteralPath $resolvedStage -File -Recurse | Sort-Object FullName) {
    $relative = [IO.Path]::GetRelativePath($resolvedStage, $file.FullName).Replace('\', '/')
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    "$hash  $relative"
}
$checksumLines | Set-Content -LiteralPath (Join-Path $resolvedStage 'checksums.sha256') -Encoding utf8NoBOM

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$archive = Join-Path $outputRoot "$packageName.zip"
if (Test-Path -LiteralPath $archive) {
    Remove-Item -LiteralPath $archive -Force
}
if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
    Compress-Archive -Path (Join-Path $resolvedStage '*') -DestinationPath $archive -CompressionLevel Optimal
}
else {
    & chmod 0755 (Join-Path $resolvedStage 'bin/beamtrace')
    if ($LASTEXITCODE -ne 0) { throw 'Could not mark the POSIX launcher executable.' }
    Push-Location $resolvedStage
    try {
        & zip -q -r $archive .
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the portable ZIP archive.' }
    }
    finally {
        Pop-Location
    }
}
$baselinePath = Join-Path $repoRoot 'packaging/archive-size-baselines.json'
$baselines = Get-Content -Raw -LiteralPath $baselinePath | ConvertFrom-Json
$baselineKey = "$platform-$architecture"
$baselineProperty = $baselines.archives.PSObject.Properties[$baselineKey]
if ($null -eq $baselineProperty -or [long]$baselineProperty.Value -le 0) {
    throw "Archive size baseline is missing for $baselineKey."
}
$growthPercent = [double]$baselines.maximum_growth_percent
if ($growthPercent -lt 0 -or $growthPercent -gt 100) {
    throw "Archive growth percentage is invalid: $growthPercent"
}
$baselineBytes = [long]$baselineProperty.Value
$maximumBytes = [long][Math]::Floor($baselineBytes * (1.0 + ($growthPercent / 100.0)))
$archiveBytes = (Get-Item -LiteralPath $archive).Length
if ($archiveBytes -gt $maximumBytes) {
    throw "Archive $baselineKey is $archiveBytes bytes; maximum is $maximumBytes bytes ($growthPercent% above the $($baselines.source_release) baseline of $baselineBytes)."
}
Write-Host "Archive size gate passed for ${baselineKey}: $archiveBytes / $maximumBytes bytes."
$archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
"$archiveHash  $([IO.Path]::GetFileName($archive))" | Set-Content -LiteralPath "$archive.sha256" -Encoding ascii
Write-Output $archive
