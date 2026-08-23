# SPDX-License-Identifier: Apache-2.0 OR MIT

function Get-BeamTraceVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $versionPath = Join-Path $root 'version.txt'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        throw 'The canonical version.txt file is missing.'
    }

    $versionSource = (Get-Content -Raw -LiteralPath $versionPath).Trim()
    if ($versionSource -notmatch '^(?<version>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?)$') {
        throw 'version.txt does not contain one supported semantic version.'
    }
    $version = $Matches.version

    $packageFiles = @(
        'packages/beamtrace_core/gleam.toml',
        'packages/beamtrace_runtime/gleam.toml',
        'packages/beamtrace_tui/gleam.toml',
        'packages/beamtrace_web/gleam.toml'
    )
    foreach ($relative in $packageFiles) {
        $path = Join-Path $root $relative
        $match = Select-String -LiteralPath $path -Pattern '^version = "([^"]+)"$' | Select-Object -First 1
        if ($null -eq $match) { throw "Package version is missing: $relative" }
        $actual = $match.Matches[0].Groups[1].Value
        if ($actual -ne $version) {
            throw "Project version $version does not match ${relative}: $actual"
        }
    }

    $runtimeVersionPath = Join-Path $root 'packages/beamtrace_runtime/src/beamtrace_runtime/internal/version.gleam'
    $runtimeSource = Get-Content -Raw -LiteralPath $runtimeVersionPath
    if (-not $runtimeSource.Contains('// x-release-please-start-version') -or -not $runtimeSource.Contains('// x-release-please-end')) {
        throw 'The runtime version is not enclosed by release-please generic updater markers.'
    }
    $runtimeMatch = Select-String -LiteralPath $runtimeVersionPath -Pattern '^pub const current = "([^"]+)"$' | Select-Object -First 1
    if ($null -eq $runtimeMatch) { throw 'The release-managed runtime version constant is missing.' }
    $runtimeVersion = $runtimeMatch.Matches[0].Groups[1].Value
    if ($runtimeVersion -ne $version) {
        throw "Project version $version does not match the runtime version: $runtimeVersion"
    }

    foreach ($relative in @(
        'packages/beamtrace_runtime/manifest.toml',
        'packages/beamtrace_tui/manifest.toml',
        'packages/beamtrace_web/manifest.toml'
    )) {
        $path = Join-Path $root $relative
        $source = Get-Content -Raw -LiteralPath $path
        $localPackages = [regex]::Matches(
            $source,
            '(?m)^\s*\{[^\r\n]*?version = "([^"]+)"[^\r\n]*?source = "local"[^\r\n]*\},?\s*$'
        )
        if ($localPackages.Count -eq 0) {
            throw "Lockfile has no local packages to validate: $relative"
        }
        foreach ($match in $localPackages) {
            $lockedVersion = $match.Groups[1].Value
            if ($lockedVersion -ne $version) {
                throw "Project version $version does not match a local package in ${relative}: $lockedVersion"
            }
        }
    }

    return $version
}
