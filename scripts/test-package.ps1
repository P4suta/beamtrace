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
    $packagedErtsCommands = @(Get-ChildItem -LiteralPath (Join-Path $ertsDirectories[0].FullName 'bin') -File)
    foreach ($developmentCommand in @('ct_run', 'dialyzer', 'erlc', 'typer', 'yielding_c_fun')) {
        if ($packagedErtsCommands.BaseName -contains $developmentCommand) {
            throw "Package contains the ERTS development command $developmentCommand."
        }
    }

    $sbom = Get-Content -Raw -LiteralPath (Join-Path $root.FullName 'SBOM.spdx.json') | ConvertFrom-Json
    if (
        $sbom.spdxVersion -ne 'SPDX-2.3' -or
        $sbom.packages.name -notcontains 'beamtrace_runtime' -or
        $sbom.packages.name -notcontains 'erlang_otp'
    ) {
        throw 'Package SBOM is not a valid BeamTrace SPDX inventory.'
    }

    $expectedSbomVersions = @{}
    $expectedSbomLocations = @{}
    foreach ($packageDirectory in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'packages') -Directory) {
        $manifestPath = Join-Path $packageDirectory.FullName 'manifest.toml'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }

        $manifestContent = Get-Content -Raw -LiteralPath $manifestPath
        foreach ($match in [regex]::Matches($manifestContent, '\{ name = "([^"]+)", version = "([^"]+)"[^\r\n]*source = "([^"]+)"')) {
            $name = $match.Groups[1].Value
            $lockedVersion = $match.Groups[2].Value
            $source = $match.Groups[3].Value
            $downloadLocation = if ($source -eq 'hex') { "https://hex.pm/packages/$name" } else { 'NOASSERTION' }
            if (
                $expectedSbomVersions.ContainsKey($name) -and
                (
                    $expectedSbomVersions[$name] -ne $lockedVersion -or
                    $expectedSbomLocations[$name] -ne $downloadLocation
                )
            ) {
                throw "Immediate package manifests disagree on the locked source for ${name}."
            }
            $expectedSbomVersions[$name] = $lockedVersion
            $expectedSbomLocations[$name] = $downloadLocation
        }
    }
    foreach ($name in @('beamtrace_core', 'beamtrace_runtime', 'beamtrace_web', 'beamtrace_tui', 'beamtrace_agent')) {
        $expectedSbomVersions[$name] = $projectVersion
        $expectedSbomLocations[$name] = 'NOASSERTION'
    }
    $expectedSbomVersions['erlang_otp'] = $otpVersion
    $expectedSbomLocations['erlang_otp'] = 'https://github.com/erlang/otp'

    $actualSbomPackages = @{}
    foreach ($package in @($sbom.packages)) {
        $name = [string]$package.name
        if ($actualSbomPackages.ContainsKey($name)) {
            throw "Package SBOM contains duplicate package entries for $name."
        }
        $actualSbomPackages[$name] = $package
    }
    $missingSbomPackages = @($expectedSbomVersions.Keys | Where-Object {
        -not $actualSbomPackages.ContainsKey($_)
    })
    $unexpectedSbomPackages = @($actualSbomPackages.Keys | Where-Object {
        -not $expectedSbomVersions.ContainsKey($_)
    })
    if ($missingSbomPackages.Count -gt 0 -or $unexpectedSbomPackages.Count -gt 0) {
        throw "Package SBOM inventory differs from immediate manifests; missing=[$($missingSbomPackages -join ', ')] unexpected=[$($unexpectedSbomPackages -join ', ')]"
    }
    foreach ($name in $expectedSbomVersions.Keys) {
        $actualVersion = [string]$actualSbomPackages[$name].versionInfo
        if ($actualVersion -ne $expectedSbomVersions[$name]) {
            throw "Package SBOM version mismatch for ${name}: expected $($expectedSbomVersions[$name]), found $actualVersion"
        }
        $actualLocation = [string]$actualSbomPackages[$name].downloadLocation
        if ($actualLocation -ne $expectedSbomLocations[$name]) {
            throw "Package SBOM source mismatch for ${name}: expected $($expectedSbomLocations[$name]), found $actualLocation"
        }
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
        if (-not $IsWindows) {
            # No Erlang toolchain, but the POSIX utilities every host has and the
            # bundled erl launcher script needs.
            foreach ($utility in @('dirname', 'basename', 'uname', 'sed', 'sh', 'env')) {
                $source = Get-Command $utility -ErrorAction SilentlyContinue
                if ($null -ne $source) {
                    New-Item -ItemType SymbolicLink -Path (Join-Path $emptyPath $utility) -Target $source.Source | Out-Null
                }
            }
        }
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
        $demoRoot = Join-Path $resolvedTestRoot 'demo-cwd'
        $demoTemp = Join-Path $resolvedTestRoot 'demo-temp'
        New-Item -ItemType Directory -Path $demoRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $demoTemp -Force | Out-Null
        $previousTemp = @{ TMPDIR = $env:TMPDIR; TEMP = $env:TEMP; TMP = $env:TMP }
        $env:TMPDIR = $demoTemp
        $env:TEMP = $demoTemp
        $env:TMP = $demoTemp
        Push-Location $demoRoot
        try {
            $demo = (& $launcher demo --no-ui --json | Out-String)
            if ($LASTEXITCODE -ne 0) {
                throw "Self-contained package demo failed without a host Erlang runtime (exit $LASTEXITCODE): $demo"
            }
            $demoResult = $demo | ConvertFrom-Json
            if ($demoResult.command -ne 'demo' -or -not $demoResult.ok -or $demoResult.artifact.retained -or $demoResult.artifact.event_count -lt 1) {
                throw "Self-contained package demo did not report a temporary sealed archive: $demo"
            }
            Write-Host "Self-contained package demo recorded $($demoResult.artifact.event_count) events without a host Erlang runtime."
            $missingTool = (& $launcher record --trigger 'erlang:system_time/0' --no-ui '--' erl -noshell -eval 'halt().' 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 2 -or $missingTool -notmatch 'beamtrace\[E_COMMAND_NOT_FOUND\]') {
                throw "Self-contained package record must explain a missing host Erlang toolchain: $missingTool"
            }
        }
        finally {
            Pop-Location
            foreach ($name in $previousTemp.Keys) {
                if ($null -eq $previousTemp[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue } else { Set-Item "Env:$name" $previousTemp[$name] }
            }
        }
        if (Test-Path -LiteralPath (Join-Path $demoRoot 'erl_crash.dump')) {
            throw 'Self-contained package demo left erl_crash.dump in the working directory.'
        }
        $leftovers = @(Get-ChildItem -LiteralPath $demoTemp -Force -ErrorAction SilentlyContinue)
        if ($leftovers.Count -ne 0) {
            throw "Self-contained package demo left temporary entries behind: $($leftovers.Name -join ', ')"
        }
        $env:PATH = $previousPath

        $configRoot = Join-Path $resolvedTestRoot 'project-config'
        New-Item -ItemType Directory -Path $configRoot -Force | Out-Null
        Push-Location $configRoot
        try {
            & $launcher init
            if ($LASTEXITCODE -ne 0) {
                throw "Packaged beamtrace init failed with exit code $LASTEXITCODE."
            }
            $configPath = Join-Path $configRoot 'beamtrace.toml'
            if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
                throw 'Packaged beamtrace init did not create beamtrace.toml.'
            }
            $initialConfigHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash
            $configCheck = (& $launcher config check | Out-String)
            if ($LASTEXITCODE -ne 0 -or $configCheck -notmatch '^valid beamtrace\.toml: 1 profile\(s\)') {
                throw 'Packaged beamtrace config check did not validate the generated profile.'
            }
            & $launcher init | Out-Null
            if ($LASTEXITCODE -ne 2) {
                throw "A second packaged beamtrace init must exit 2, got $LASTEXITCODE."
            }
            $finalConfigHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash
            if ($finalConfigHash -ne $initialConfigHash) {
                throw 'A second packaged beamtrace init modified the existing configuration.'
            }
        }
        finally {
            Pop-Location
        }

        & (Join-Path $PSScriptRoot 'test-record-dogfood.ps1') -Launcher $launcher
        if ($LASTEXITCODE -ne 0) {
            throw "Self-contained package record dogfood failed with exit code $LASTEXITCODE."
        }

        if (-not $IsWindows) {
            $signalTemp = Join-Path $resolvedTestRoot 'record-signal-temp'
            New-Item -ItemType Directory -Path $signalTemp -Force | Out-Null
            $signalInfo = [Diagnostics.ProcessStartInfo]::new()
            $signalInfo.FileName = $launcher
            foreach ($argument in @(
                'record',
                '--trigger', 'erlang:system_time/0',
                '--out', (Join-Path $signalTemp 'unused.beamtrace'),
                '--', (Get-Command erl -ErrorAction Stop).Source,
                '-noshell', '-eval', 'receive beamtrace_never -> ok end.'
            )) {
                $signalInfo.ArgumentList.Add($argument)
            }
            $signalInfo.UseShellExecute = $false
            $signalInfo.RedirectStandardOutput = $true
            $signalInfo.RedirectStandardError = $true
            $signalInfo.Environment['TMPDIR'] = $signalTemp
            $signalProcess = [Diagnostics.Process]::new()
            $signalProcess.StartInfo = $signalInfo
            if (-not $signalProcess.Start()) {
                throw 'Could not start the packaged record signal fixture.'
            }
            try {
                $gateSeen = $false
                foreach ($attempt in 1..500) {
                    if (@(Get-ChildItem -LiteralPath $signalTemp -Directory -Filter 'beamtrace-record-*').Count -gt 0) {
                        $gateSeen = $true
                        break
                    }
                    if ($signalProcess.HasExited) { break }
                    Start-Sleep -Milliseconds 20
                }
                if (-not $gateSeen) {
                    throw 'Packaged record did not create its private signal-test gate.'
                }
                & kill -TERM $signalProcess.Id
                if ($LASTEXITCODE -ne 0) {
                    throw 'Could not send SIGTERM to the packaged record launcher.'
                }
                if (-not $signalProcess.WaitForExit(10000)) {
                    throw 'Packaged record did not stop after SIGTERM within 10 seconds.'
                }
                $signalOutput = $signalProcess.StandardOutput.ReadToEnd()
                $signalError = $signalProcess.StandardError.ReadToEnd()
                if ($signalProcess.ExitCode -ne 143) {
                    throw "Packaged record exited with $($signalProcess.ExitCode), expected 143 after SIGTERM:`n$signalOutput`n$signalError"
                }
                $remainingGates = @(Get-ChildItem -LiteralPath $signalTemp -Directory -Filter 'beamtrace-record-*')
                if ($remainingGates.Count -ne 0) {
                    throw "Packaged record left $($remainingGates.Count) private gate director$(if ($remainingGates.Count -eq 1) { 'y' } else { 'ies' }) after SIGTERM."
                }
            }
            finally {
                if (-not $signalProcess.HasExited) {
                    $signalProcess.Kill($true)
                    $signalProcess.WaitForExit(10000) | Out-Null
                }
                $signalProcess.Dispose()
            }
        }

        $teamData = Join-Path $resolvedTestRoot 'team-data'
        $jwksPath = Join-Path $resolvedTestRoot 'jwks.json'
        '{"keys":[{"kty":"RSA","kid":"package-test","use":"sig","alg":"RS256","n":"AQ","e":"Aw"}]}' |
            Set-Content -LiteralPath $jwksPath -Encoding utf8NoBOM
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
            if (-not $IsWindows) {
                & kill -INT $teamProcess.Id
                if ($LASTEXITCODE -ne 0) {
                    throw 'Could not send SIGINT to the packaged team server.'
                }
                if (-not $teamProcess.WaitForExit(10000)) {
                    throw 'Packaged team server did not stop after SIGINT within 10 seconds.'
                }
                if ($teamProcess.ExitCode -ne 0) {
                    $teamError = $teamProcess.StandardError.ReadToEnd()
                    throw "Packaged team server exited with $($teamProcess.ExitCode) after SIGINT: $teamError"
                }
                $teamOutput = $teamProcess.StandardOutput.ReadToEnd()
                $teamError = $teamProcess.StandardError.ReadToEnd()
                if ("$teamOutput`n$teamError" -notmatch 'server\.closed') {
                    throw 'Packaged team server did not log a clean close after SIGINT.'
                }
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
