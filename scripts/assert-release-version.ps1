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
. (Join-Path $PSScriptRoot 'project-version.ps1')
$projectVersion = Get-BeamTraceVersion -RepositoryRoot $repoRoot
if ($projectVersion -ne $tagVersion) {
    throw "Release tag $Tag does not match project version $projectVersion"
}

Write-Host "Release version $tagVersion is consistent."
exit 0
