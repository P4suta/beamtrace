# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Tag
)

$ErrorActionPreference = 'Stop'
if ($Tag -notmatch '^v(?<version>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?)$') {
    throw "Release tag is not a supported semantic version: $Tag"
}
$tagVersion = $Matches.version
$repoRoot = Split-Path -Parent $PSScriptRoot
$manifests = @(
    'packages/beamtrace_core/gleam.toml',
    'packages/beamtrace_runtime/gleam.toml',
    'packages/beamtrace_web/gleam.toml',
    'packages/beamtrace_tui/gleam.toml'
)
foreach ($relative in $manifests) {
    $path = Join-Path $repoRoot $relative
    $versionMatch = Select-String -LiteralPath $path -Pattern '^version = "([^"]+)"$' | Select-Object -First 1
    if ($null -eq $versionMatch) { throw "Package version is missing: $relative" }
    $packageVersion = $versionMatch.Matches[0].Groups[1].Value
    if ($packageVersion -ne $tagVersion) {
        throw "Release tag $Tag does not match ${relative}: $packageVersion"
    }
}

Write-Host "Release version $tagVersion is consistent."
exit 0
