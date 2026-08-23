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

$runtimeToml = Join-Path $repoRoot 'packages/beamtrace_runtime/gleam.toml'
$versionMatch = Select-String -LiteralPath $runtimeToml -Pattern '^version = "([^"]+)"$' | Select-Object -First 1
if ($null -eq $versionMatch) { throw 'Could not determine the BeamTrace version.' }
$version = $versionMatch.Matches[0].Groups[1].Value

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
foreach ($manifest in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'packages') -Filter manifest.toml -Recurse) {
    $content = Get-Content -Raw -LiteralPath $manifest.FullName
    foreach ($match in [regex]::Matches($content, '\{ name = "([^"]+)", version = "([^"]+)"[^\r\n]*source = "([^"]+)"')) {
        $name = $match.Groups[1].Value
        $inventory[$name] = [pscustomobject]@{
            SPDXID = 'SPDXRef-Package-' + ($name -replace '[^A-Za-z0-9.-]', '-')
            name = $name
            versionInfo = $match.Groups[2].Value
            downloadLocation = if ($match.Groups[3].Value -eq 'hex') { "https://hex.pm/packages/$name" } else { 'NOASSERTION' }
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
$archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
"$archiveHash  $([IO.Path]::GetFileName($archive))" | Set-Content -LiteralPath "$archive.sha256" -Encoding ascii
Write-Output $archive
