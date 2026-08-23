# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$CompilerArguments = [regex]::Matches(
    $env:BEAMTRACE_NIF_CC_ARGS,
    '(?:"([^"]*)"|(\S+))'
) | ForEach-Object {
    if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
}

function Import-VisualStudioEnvironment {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw 'Visual Studio Build Tools with the C++ workload are required to compile SQLite.'
    }
    $installation = & $vswhere -latest -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installation)) {
        throw 'Visual Studio Build Tools with the C++ workload are required to compile SQLite.'
    }
    $developerShell = Join-Path $installation.Trim() 'Common7\Tools\VsDevCmd.bat'
    $environment = & cmd.exe /d /s /c "`"$developerShell`" -arch=amd64 -host_arch=amd64 >nul && set"
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not initialize the Visual Studio C++ environment.'
    }
    foreach ($line in $environment) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            $name = $line.Substring(0, $separator)
            $value = $line.Substring($separator + 1)
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

function Invoke-Compile([string[]] $Arguments) {
    $translated = [System.Collections.Generic.List[string]]::new()
    $translated.Add('/nologo')
    $translated.Add('/c')
    $translated.Add('/O1')
    $translated.Add('/W0')
    $translated.Add('/utf-8')
    $output = $null

    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = $Arguments[$index]
        switch -Regex ($argument) {
            '^-c$' { continue }
            '^-o$' {
                $index++
                $output = $Arguments[$index]
                continue
            }
            '^-(Os|g|Wall|fPIC|MMD)$' { continue }
            '^-D' {
                $translated.Add('/D' + $argument.Substring(2))
                continue
            }
            '^-I' {
                $translated.Add('/I' + $argument.Substring(2))
                continue
            }
            '\.c$' {
                $translated.Add($argument)
                continue
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($output)) {
        throw 'The port compiler did not supply an object output path.'
    }
    $translated.Add('/Fo' + $output)
    & cl.exe @translated
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Invoke-Link([string[]] $Arguments) {
    $translated = [System.Collections.Generic.List[string]]::new()
    $translated.Add('/NOLOGO')
    $translated.Add('/DLL')
    $output = $null

    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = $Arguments[$index]
        switch -Regex ($argument) {
            '^-o$' {
                $index++
                $output = $Arguments[$index]
                continue
            }
            '^-shared$' { continue }
            '^-L' {
                $translated.Add('/LIBPATH:' + $argument.Substring(2))
                continue
            }
            '^-l' {
                $translated.Add($argument.Substring(2) + '.lib')
                continue
            }
            '\.obj$' {
                $translated.Add($argument)
                continue
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($output)) {
        throw 'The port compiler did not supply a shared-library output path.'
    }
    $translated.Add('/OUT:' + $output)
    & link.exe @translated
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Import-VisualStudioEnvironment
if ($CompilerArguments -contains '-c') {
    Invoke-Compile $CompilerArguments
    exit 0
}

Invoke-Link $CompilerArguments
exit 0
