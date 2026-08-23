# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project-version.ps1')
$projectVersion = Get-BeamTraceVersion -RepositoryRoot $repoRoot

function Remove-PackageTestDirectory {
    param([Parameter(Mandatory)][string]$Path)

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq 20) { throw }
            Start-Sleep -Milliseconds 250
        }
    }
}

$archiveOutput = & (Join-Path $PSScriptRoot 'package.ps1') -SkipTests
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$archive = @($archiveOutput | Where-Object { $_ -is [string] -and $_.EndsWith('.zip') })[-1]
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    throw "Package archive was not produced: $archive"
}

$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $launcherEntry = $zip.GetEntry('bin/beamtrace')
    if ($null -eq $launcherEntry) { throw 'Package is missing the POSIX launcher entry.' }
    if (-not $IsWindows) {
        $attributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes($launcherEntry.ExternalAttributes), 0)
        $unixMode = ($attributes -shr 16) -band 0xffff
        if (($unixMode -band 0x49) -ne 0x49) {
            throw "POSIX launcher is not executable in the ZIP metadata: mode 0x$($unixMode.ToString('x'))"
        }
    }
}
finally {
    $zip.Dispose()
}

$testRoot = Join-Path $repoRoot ".build/package-test-$PID"
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$resolvedBuildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.build'))
if (-not $resolvedTestRoot.StartsWith($resolvedBuildRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe package test directory: $resolvedTestRoot"
}

New-Item -ItemType Directory -Path $resolvedTestRoot -Force | Out-Null
try {
    Expand-Archive -LiteralPath $archive -DestinationPath $resolvedTestRoot -Force
    $root = Get-Item -LiteralPath $resolvedTestRoot
    $unexpectedWrapper = Join-Path $resolvedTestRoot ([IO.Path]::GetFileNameWithoutExtension($archive))
    if (Test-Path -LiteralPath $unexpectedWrapper -PathType Container) {
        throw 'Package must expose bin/lib directly without an architecture-named wrapper directory.'
    }

    $required = @(
        'bin/beamtrace',
        'bin/beamtrace.ps1',
        'lib/beamtrace.escript',
        'lib/beamtrace_agent.beam',
        'lib/native/esqlite/ebin/esqlite.app',
        'share/beamtrace/web/index.html',
        'share/beamtrace/web/beamtrace_web.js',
        'runtime/OTP_VERSION',
        'LICENSES/MIT.txt',
        'LICENSES/Apache-2.0.txt',
        'SBOM.spdx.json',
        'checksums.sha256'
    )
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $root.FullName $relative) -PathType Leaf)) {
            throw "Package is missing $relative"
        }
    }
    $packagedNif = Get-ChildItem -LiteralPath (Join-Path $root.FullName 'lib/native/esqlite/priv') -File | Where-Object {
        $_.BaseName -eq 'esqlite3_nif' -and $_.Extension -in @('.dll', '.so', '.dylib')
    }
    if (@($packagedNif).Count -ne 1) {
        throw 'Package must contain exactly one platform SQLite NIF.'
    }

    $otpVersion = (Get-Content -Raw -LiteralPath (Join-Path $root.FullName 'runtime/OTP_VERSION')).Trim()
    if ($otpVersion -notmatch '^(27|28|29)(\.|$)') {
        throw "Package contains an unsupported OTP runtime: $otpVersion"
    }
    $ertsDirectories = @(Get-ChildItem -LiteralPath (Join-Path $root.FullName 'runtime') -Directory -Filter 'erts-*')
    if ($ertsDirectories.Count -ne 1) {
        throw "Package must contain exactly one ERTS runtime, found $($ertsDirectories.Count)."
    }
    $bundledEscriptName = if ($IsWindows) { 'escript.exe' } else { 'escript' }
    $bundledEscript = Join-Path $ertsDirectories[0].FullName "bin/$bundledEscriptName"
    if (-not (Test-Path -LiteralPath $bundledEscript -PathType Leaf)) {
        throw 'Package is missing its bundled escript executable.'
    }

    $sbom = Get-Content -Raw -LiteralPath (Join-Path $root.FullName 'SBOM.spdx.json') | ConvertFrom-Json
    if (
        $sbom.spdxVersion -ne 'SPDX-2.3' -or
        $sbom.packages.name -notcontains 'beamtrace_runtime' -or
        $sbom.packages.name -notcontains 'erlang_otp'
    ) {
        throw 'Package SBOM is not a valid BeamTrace SPDX inventory.'
    }

    $checksumLines = Get-Content -LiteralPath (Join-Path $root.FullName 'checksums.sha256')
    foreach ($line in $checksumLines) {
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') {
            throw "Malformed checksum line: $line"
        }
        $file = Join-Path $root.FullName $Matches[2]
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Checksum references a missing file: $($Matches[2])"
        }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
        if ($actual -ne $Matches[1]) {
            throw "Checksum mismatch: $($Matches[2])"
        }
    }

    $previousAgent = $env:BEAMTRACE_AGENT_BEAM
    $previousWeb = $env:BEAMTRACE_WEB_ROOT
    $previousPath = $env:PATH
    try {
        $emptyPath = Join-Path $resolvedTestRoot 'empty-path'
        New-Item -ItemType Directory -Path $emptyPath -Force | Out-Null
        $env:PATH = $emptyPath
        $launcher = if ($IsWindows) {
            Join-Path $root.FullName 'bin/beamtrace.ps1'
        }
        else {
            Join-Path $root.FullName 'bin/beamtrace'
        }
        $version = (& $launcher version | Out-String)
        if ($LASTEXITCODE -ne 0 -or $version -notmatch ([regex]::Escape("beamtrace $projectVersion"))) {
            throw 'Self-contained package version smoke test failed without a host Erlang runtime.'
        }
        $doctor = (& $launcher doctor | Out-String)
        if ($LASTEXITCODE -ne 0 -or $doctor -notmatch 'agent BEAM: valid' -or $doctor -notmatch 'web assets: valid') {
            throw 'Self-contained package doctor smoke test failed without a host Erlang runtime.'
        }
        $env:PATH = $previousPath

        & (Join-Path $PSScriptRoot 'test-record-dogfood.ps1') -Launcher $launcher
        if ($LASTEXITCODE -ne 0) {
            throw "Self-contained package record dogfood failed with exit code $LASTEXITCODE."
        }

        $teamData = Join-Path $resolvedTestRoot 'team-data'
        $jwksPath = Join-Path $resolvedTestRoot 'jwks.json'
        '{"keys":[]}' | Set-Content -LiteralPath $jwksPath -Encoding utf8NoBOM
        $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $portProbe.Start()
        $teamPort = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
        $portProbe.Stop()
        $teamOrigin = "https://127.0.0.1:$teamPort"
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        if ($IsWindows) {
            $startInfo.FileName = (Get-Command pwsh).Source
            $startInfo.ArgumentList.Add('-NoProfile')
            $startInfo.ArgumentList.Add('-File')
            $startInfo.ArgumentList.Add($launcher)
        }
        else {
            $startInfo.FileName = $launcher
        }
        $startInfo.ArgumentList.Add('serve')
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Environment['BEAMTRACE_TEAM'] = '1'
        $startInfo.Environment['BEAMTRACE_BIND'] = '127.0.0.1'
        $startInfo.Environment['BEAMTRACE_PORT'] = [string]$teamPort
        $startInfo.Environment['BEAMTRACE_DATA_DIR'] = $teamData
        $startInfo.Environment['BEAMTRACE_ORIGIN'] = $teamOrigin
        $startInfo.Environment['BEAMTRACE_OIDC_AUTHORIZATION_ENDPOINT'] = 'https://id.example/authorize'
        $startInfo.Environment['BEAMTRACE_OIDC_TOKEN_ENDPOINT'] = 'https://id.example/token'
        $startInfo.Environment['BEAMTRACE_OIDC_ISSUER'] = 'https://id.example'
        $startInfo.Environment['BEAMTRACE_OIDC_CLIENT_ID'] = 'beamtrace-package-test'
        $startInfo.Environment['BEAMTRACE_OIDC_REDIRECT_URI'] = "$teamOrigin/auth/oidc/callback"
        $startInfo.Environment['BEAMTRACE_OIDC_JWKS_FILE'] = $jwksPath
        $startInfo.Environment['BEAMTRACE_OIDC_GROUP_ROLES'] = 'beam-admins:admin'
        $startInfo.Environment['BEAMTRACE_PROJECT'] = 'package-test'
        $startInfo.Environment['BEAMTRACE_ENVIRONMENT'] = 'acceptance'
        $teamProcess = [Diagnostics.Process]::new()
        $teamProcess.StartInfo = $startInfo
        if (-not $teamProcess.Start()) {
            throw 'Could not start packaged team server.'
        }
        try {
            $startupLine = $teamProcess.StandardOutput.ReadLineAsync()
            if (-not $startupLine.Wait(15000)) {
                throw 'Packaged team server did not start within 15 seconds.'
            }
            if ($startupLine.Result -notmatch '^BeamTrace team workspace:') {
                $teamError = $teamProcess.StandardError.ReadToEnd()
                throw "Packaged team server failed to start: $teamError"
            }
            if (-not (Test-Path -LiteralPath (Join-Path $teamData 'metadata.sqlite3') -PathType Leaf)) {
                throw 'Packaged team server did not create its SQLite metadata store.'
            }
        }
        finally {
            if (-not $teamProcess.HasExited) {
                $teamProcess.Kill($true)
                if (-not $teamProcess.WaitForExit(10000)) {
                    throw 'Packaged team server process tree did not stop within 10 seconds.'
                }
            }
            $teamProcess.Dispose()
        }
    }
    finally {
        $env:BEAMTRACE_AGENT_BEAM = $previousAgent
        $env:BEAMTRACE_WEB_ROOT = $previousWeb
        $env:PATH = $previousPath
    }
}
finally {
    Remove-PackageTestDirectory -Path $resolvedTestRoot
}

exit 0
