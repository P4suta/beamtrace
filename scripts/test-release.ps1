# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [switch] $ValidateUpstreamSchema
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project-version.ps1')

foreach ($relative in @(
    'release-please-config.json',
    '.release-please-manifest.json',
    'version.txt',
    'CHANGELOG.md',
    '.github/workflows/release-please.yml',
    '.github/workflows/release-candidate.yml',
    '.github/workflows/release.yml',
    'scripts/project-version.ps1',
    'scripts/publish-hex.ps1',
    'scripts/verify-published-release.ps1',
    'scripts/build-distribution-metadata.ps1',
    'packages/beamtrace_core/LICENSE'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $relative) -PathType Leaf)) {
        throw "Release automation file is missing: $relative"
    }
}

$version = Get-BeamTraceVersion -RepositoryRoot $repoRoot
$projectTag = "v$version"
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'assert-release-version.ps1') -Tag $projectTag
if ($LASTEXITCODE -ne 0) { throw 'The release version guard rejected the synchronized project version.' }
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'assert-release-version.ps1') -Tag v999.999.999 *> $null
if ($LASTEXITCODE -eq 0) { throw 'The release version guard accepted a mismatched tag.' }

$configPath = Join-Path $repoRoot 'release-please-config.json'
$configSource = Get-Content -Raw -LiteralPath $configPath
$config = $configSource | ConvertFrom-Json
if ($config.'$schema' -ne 'https://raw.githubusercontent.com/googleapis/release-please/v17.6.0/schemas/config.json') {
    throw 'The release-please config does not declare the upstream JSON schema.'
}
if ($ValidateUpstreamSchema) {
    $schemaResponse = Invoke-WebRequest -Uri $config.'$schema'
    if (-not ($configSource | Test-Json -Schema $schemaResponse.Content -ErrorAction Stop)) {
        throw 'release-please-config.json does not satisfy the pinned upstream schema.'
    }
}
foreach ($property in @(
    'release-type', 'version-file', 'initial-version', 'include-v-in-tag',
    'include-component-in-tag', 'draft', 'prerelease',
    'force-tag-creation', 'bump-minor-pre-major',
    'bump-patch-for-minor-pre-major', 'changelog-sections', 'packages'
)) {
    if ($config.PSObject.Properties.Name -notcontains $property) {
        throw "The release-please config is missing its schema property: $property"
    }
}
if (
    $config.'release-type' -ne 'simple' -or
    $config.'version-file' -ne 'version.txt' -or
    $config.'initial-version' -ne '0.1.0' -or
    -not $config.'include-v-in-tag' -or
    $config.'include-component-in-tag' -or
    -not $config.draft -or
    -not $config.prerelease -or
    -not $config.'force-tag-creation' -or
    -not $config.'bump-minor-pre-major' -or
    $config.'bump-patch-for-minor-pre-major' -or
    $config.'pull-request-title-pattern' -ne 'chore${scope}: release${component} ${version}'
) {
    throw 'The release-please version, tag, draft, prerelease, or 0.x bump contract drifted.'
}
if ($config.PSObject.Properties.Name -contains 'bootstrap-sha') {
    throw 'bootstrap-sha would omit existing Conventional Commits from the first changelog.'
}
$sections = @($config.'changelog-sections')
if (($sections.type -join ',') -ne 'feat,fix,security,perf') {
    throw 'Only feat, fix, security, and perf may appear in the public changelog.'
}

$packageConfig = $config.packages.PSObject.Properties['.'].Value
if ($null -eq $packageConfig -or $packageConfig.component -ne 'beamtrace') {
    throw 'The root BeamTrace release package is missing.'
}
$extraFiles = @($packageConfig.'extra-files')
if ($extraFiles.Count -ne 8 -or @($extraFiles | Where-Object { $_.path -eq 'version.txt' }).Count -ne 0) {
    throw 'The simple strategy must manage version.txt exactly once through version-file.'
}
function Assert-ExtraFile {
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [string] $Path,
        [string] $JsonPath
    )
    $match = @($extraFiles | Where-Object {
        $_.type -eq $Type -and $_.path -eq $Path -and
        (-not $PSBoundParameters.ContainsKey('JsonPath') -or $_.jsonpath -eq $JsonPath)
    })
    if ($match.Count -ne 1) {
        throw "release-please extra-file contract is missing or duplicated: $Path"
    }
}
Assert-ExtraFile -Type generic -Path 'packages/beamtrace_runtime/src/beamtrace_runtime/internal/version.gleam'
foreach ($path in @(
    'packages/beamtrace_core/gleam.toml',
    'packages/beamtrace_runtime/gleam.toml',
    'packages/beamtrace_tui/gleam.toml',
    'packages/beamtrace_web/gleam.toml'
)) {
    Assert-ExtraFile -Type toml -Path $path -JsonPath '$.version'
}
foreach ($path in @(
    'packages/beamtrace_runtime/manifest.toml',
    'packages/beamtrace_tui/manifest.toml',
    'packages/beamtrace_web/manifest.toml'
)) {
    Assert-ExtraFile -Type toml -Path $path -JsonPath '$.packages[?(@.source.value=="local")].version'
}

$versionText = (Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'version.txt')).Trim()
if ($versionText -ne $version) {
    throw 'version.txt is not managed as the simple strategy version file.'
}
$manifest = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.release-please-manifest.json') | ConvertFrom-Json
$manifestEntries = @($manifest.PSObject.Properties)
$changelog = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'CHANGELOG.md')
if ($manifestEntries.Count -eq 0) {
    if ($version -ne '0.1.0') {
        throw "The empty bootstrap manifest must begin at 0.1.0: $version"
    }
    if ($changelog.Length -ne 0) {
        throw 'CHANGELOG.md must stay empty before the first release-please PR populates it.'
    }
}
else {
    $releasedVersion = $manifest.PSObject.Properties['.'].Value
    $escapedVersion = [regex]::Escape($version)
    if ($releasedVersion -ne $version -or $changelog -notmatch "(?m)^## .*$escapedVersion") {
        throw 'The populated release manifest and changelog do not describe the synchronized release.'
    }
}

$tempRoot = Join-Path $repoRoot ".build/version-contract-$PID"
$resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
$resolvedBuild = [IO.Path]::GetFullPath((Join-Path $repoRoot '.build'))
if (-not $resolvedTemp.StartsWith($resolvedBuild, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe version contract directory: $resolvedTemp"
}
if (Test-Path -LiteralPath $resolvedTemp) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
New-Item -ItemType Directory -Path $resolvedTemp -Force | Out-Null
try {
    foreach ($relative in @(
        'version.txt',
        'packages/beamtrace_core/gleam.toml',
        'packages/beamtrace_runtime/gleam.toml',
        'packages/beamtrace_tui/gleam.toml',
        'packages/beamtrace_web/gleam.toml',
        'packages/beamtrace_runtime/manifest.toml',
        'packages/beamtrace_tui/manifest.toml',
        'packages/beamtrace_web/manifest.toml',
        'packages/beamtrace_runtime/src/beamtrace_runtime/internal/version.gleam'
    )) {
        $destination = Join-Path $resolvedTemp $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $destination
    }
    $negativePackage = Join-Path $resolvedTemp 'packages/beamtrace_web/gleam.toml'
    (Get-Content -Raw -LiteralPath $negativePackage).Replace("version = `"$version`"", 'version = "9.9.9"') |
        Set-Content -LiteralPath $negativePackage -Encoding utf8NoBOM
    $rejected = $false
    try { Get-BeamTraceVersion -RepositoryRoot $resolvedTemp | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'The version reader accepted a mismatched package manifest.' }

    Copy-Item -LiteralPath (Join-Path $repoRoot 'packages/beamtrace_web/gleam.toml') -Destination $negativePackage -Force
    $negativeLock = Join-Path $resolvedTemp 'packages/beamtrace_runtime/manifest.toml'
    $lockSource = Get-Content -Raw -LiteralPath $negativeLock
    $localVersionPattern = [regex]::new(
        "(?m)^(\s*\{ name = `"beamtrace_core`", version = `")$([regex]::Escape($version))(`"[^\r\n]*source = `"local`")"
    )
    $lockSource = $localVersionPattern.Replace($lockSource, '${1}9.9.9${2}', 1)
    $lockSource | Set-Content -LiteralPath $negativeLock -Encoding utf8NoBOM
    $rejected = $false
    try { Get-BeamTraceVersion -RepositoryRoot $resolvedTemp | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'The version reader accepted a mismatched local lockfile package.' }

    Copy-Item -LiteralPath (Join-Path $repoRoot 'packages/beamtrace_runtime/manifest.toml') -Destination $negativeLock -Force
    $negativeRuntime = Join-Path $resolvedTemp 'packages/beamtrace_runtime/src/beamtrace_runtime/internal/version.gleam'
    (Get-Content -Raw -LiteralPath $negativeRuntime).Replace(
        "pub const current = `"$version`"",
        'pub const current = "9.9.9"'
    ) | Set-Content -LiteralPath $negativeRuntime -Encoding utf8NoBOM
    $rejected = $false
    try { Get-BeamTraceVersion -RepositoryRoot $resolvedTemp | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'The version reader accepted a mismatched runtime constant.' }
}
finally {
    if (Test-Path -LiteralPath $resolvedTemp) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

$releasePleaseWorkflow = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github/workflows/release-please.yml')
foreach ($marker in @(
    'branches: [main]',
    'environment: release-automation',
    'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1',
    'googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7',
    'client-id: ${{ vars.RELEASE_PLEASE_APP_CLIENT_ID }}',
    'private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}',
    'permission-contents: write',
    'permission-pull-requests: write',
    'permission-issues: write'
)) {
    if (-not $releasePleaseWorkflow.Contains($marker)) {
        throw "Release Please workflow is missing: $marker"
    }
}

$candidate = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github/workflows/release-candidate.yml')
foreach ($marker in @(
    'types: [opened, synchronize, reopened]',
    "'autorelease: pending'",
    "'release-please--branches--'",
    'runner: ubuntu-latest',
    'runner: ubuntu-24.04-arm',
    'runner: windows-latest',
    'runner: macos-15-intel',
    'runner: macos-15',
    './scripts/package.ps1 -SkipTests',
    './scripts/test-hex-package.ps1',
    './scripts/test-oci.ps1 -Build',
    './scripts/build-distribution-metadata.ps1',
    'name: Release Candidate Gate'
)) {
    if (-not $candidate.Contains($marker)) { throw "Release candidate workflow is missing: $marker" }
}
if ($candidate.Contains('types: [opened, synchronize, reopened, labeled]')) {
    throw 'Release candidate workflow must not rerun when release-please adds its label.'
}
if ($candidate.Contains('runner: windows-11-arm')) {
    throw 'Release candidate workflow must not label an x64 Erlang runtime as native Windows ARM64.'
}

$releaseWorkflow = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github/workflows/release.yml')
foreach ($marker in @(
    "tags: ['v*']",
    'workflow_dispatch:',
    'RELEASE_TAG:',
    'RELEASE_SHA:',
    'resolved_sha=',
    'ref: ${{ env.RELEASE_SHA }}',
    'runner: ubuntu-24.04-arm',
    'runner: windows-latest',
    'runner: macos-15-intel',
    'runner: macos-15',
    'name: Require release-please draft',
    'gh api --paginate --slurp',
    'releases?per_page=100',
    'if length == 1 then .[0]',
    '.draft == true and .prerelease == true',
    './scripts/assert-release-version.ps1 -Tag',
    './scripts/package.ps1 -SkipTests',
    './scripts/test-hex-package.ps1',
    'Get-Item -LiteralPath "packages/beamtrace_core/build/beamtrace_core-$version.tar"',
    './scripts/test-oci.ps1 -Build',
    './scripts/build-distribution-metadata.ps1',
    'needs: [package, hex, image, metadata]',
    'ref: ${{ github.workflow_sha }}',
    'path: release-source',
    'path: release-tools',
    './release-tools/scripts/publish-hex.ps1',
    '-RepositoryRoot $releaseSource',
    'sha-$RELEASE_SHA',
    'org.opencontainers.image.revision',
    'manifest unknown',
    'Could not safely determine whether immutable image tag exists',
    'version_digest',
    './scripts/verify-published-release.ps1',
    'gh release upload "$RELEASE_TAG" dist/* --clobber',
    '-F draft=false',
    '-F prerelease=true',
    '-f name="BeamTrace $RELEASE_TAG"',
    'id-token: write',
    'attestations: write',
    'packages: write',
    'actions/attest@'
)) {
    if (-not $releaseWorkflow.Contains($marker)) { throw "Release workflow is missing: $marker" }
}
if ($releaseWorkflow.Contains('releases/tags/')) {
    throw 'The release workflow must list releases because GitHub excludes drafts from the published-release tag endpoint.'
}
if ($releaseWorkflow.Contains('Get-Item -LiteralPath packages/beamtrace_core/build/beamtrace_core-*.tar')) {
    throw 'PowerShell LiteralPath must not be used with a wildcard when locating the Hex tarball.'
}
$draftReleaseListCount = [regex]::Matches(
    $releaseWorkflow,
    [regex]::Escape('gh api --paginate --slurp')
).Count
if ($draftReleaseListCount -ne 2) {
    throw "Expected both the draft guard and final publisher to list draft releases; found $draftReleaseListCount lookups."
}
if ($releaseWorkflow -notmatch '(?ms)^  draft-release:.*?^    permissions:\s*\r?\n(?:\s*#.*\r?\n)?      contents: write\s*$') {
    throw 'The draft release guard needs push-equivalent Contents access to see GitHub draft releases.'
}
$releaseCheckoutCount = [regex]::Matches(
    $releaseWorkflow,
    [regex]::Escape('ref: ${{ env.RELEASE_SHA }}')
).Count
if ($releaseCheckoutCount -ne 6) {
    throw "Every release source checkout must use the verified immutable commit; found $releaseCheckoutCount."
}
$releaseToolingCheckoutCount = [regex]::Matches(
    $releaseWorkflow,
    [regex]::Escape('ref: ${{ github.workflow_sha }}')
).Count
if ($releaseToolingCheckoutCount -ne 1) {
    throw "The Hex publisher must use exactly one checkout of the audited workflow tooling; found $releaseToolingCheckoutCount."
}
if ($releaseWorkflow -notmatch '(?ms)^  publish-hex:.*?ref: \$\{\{ env\.RELEASE_SHA \}\}.*?path: release-source.*?ref: \$\{\{ github\.workflow_sha \}\}.*?path: release-tools.*?\./release-tools/scripts/publish-hex\.ps1.*?-RepositoryRoot \$releaseSource') {
    throw 'The Hex publisher must keep immutable release source separate from the audited workflow tooling.'
}
foreach ($legacyContext in @('$GITHUB_REF_NAME', '$GITHUB_SHA')) {
    if ($releaseWorkflow.Contains($legacyContext)) {
        throw "Release workflow bypasses the verified recovery context: $legacyContext"
    }
}
if (
    -not $releaseWorkflow.Contains("-name 'beamtrace-*.zip' | wc -l)`" -eq 5") -or
    -not $releaseWorkflow.Contains("-name 'beamtrace-*.zip.sha256' | wc -l)`" -eq 5")
) {
    throw 'GitHub Release publication must require exactly five supported native archives and sidecars.'
}
if ($releaseWorkflow.Contains('gh release create') -or $releaseWorkflow.Contains(':latest')) {
    throw 'The tag workflow must use the existing draft and must not publish a mutable latest image.'
}
if ($releaseWorkflow.Contains('runner: windows-11-arm')) {
    throw 'Release workflow must not label an x64 Erlang runtime as native Windows ARM64.'
}
$hexPublisher = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/publish-hex.ps1')
foreach ($marker in @(
    'metadata.config',
    'contents.tar.gz',
    'Get-FileHash',
    '[string] $RepositoryRoot',
    "Join-Path `$repoRoot 'scripts/project-version.ps1'",
    "'I am not using semantic versioning' | & gleam publish --yes",
    'already exists',
    'repo.hex.pm/tarballs'
)) {
    if (-not $hexPublisher.Contains($marker)) { throw "Hex idempotency contract is missing: $marker" }
}
if ($hexPublisher.Contains('--replace')) {
    throw 'Hex publication must never replace an existing package version.'
}

foreach ($workflowPath in @(
    '.github/workflows/release-please.yml',
    '.github/workflows/release-candidate.yml',
    '.github/workflows/release.yml'
)) {
    $source = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $workflowPath)
    foreach ($match in [regex]::Matches($source, '(?m)^\s*- uses:\s*([^\s#]+)')) {
        $action = $match.Groups[1].Value
        if ($action -notmatch '@[0-9a-f]{40}$') {
            throw "Release Action is not pinned to a full commit SHA in ${workflowPath}: $action"
        }
    }
}

$fixedVersionScripts = @(
    'scripts/test-cli-smoke.ps1',
    'scripts/test-package.ps1',
    'scripts/test-oci.ps1',
    'scripts/test-hex-package.ps1',
    'scripts/test-distribution-metadata.ps1'
)
foreach ($relative in $fixedVersionScripts) {
    $source = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $relative)
    if (-not $source.Contains('Get-BeamTraceVersion')) {
        throw "Packaging boundary does not use the common version reader: $relative"
    }
    if ($source -match 'beamtrace 0\\?\.1\\?\.0' -or $source.Contains('beamtrace_core-0.1.0.tar')) {
        throw "Packaging boundary still freezes the bootstrap version: $relative"
    }
}

Write-Host 'Release automation acceptance passed without publishing.'
exit 0
