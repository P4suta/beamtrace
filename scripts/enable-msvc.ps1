# SPDX-License-Identifier: Apache-2.0 OR MIT
$isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if (-not $isWindowsHost -or $null -ne (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    return
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Visual Studio Build Tools with the C++ workload are required to build SQLite on Windows.'
}
$installation = & $vswhere -latest -products '*' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installation)) {
    throw 'Visual Studio Build Tools with the C++ workload are required to build SQLite on Windows.'
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
        Set-Item -Path "env:$name" -Value $value
    }
}
