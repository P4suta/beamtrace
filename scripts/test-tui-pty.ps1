# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if (-not $IsLinux) {
    Write-Host 'TUI PTY acceptance: skipped (Linux CI owns the util-linux PTY boundary)'
    exit 0
}

$harness = Join-Path $PSScriptRoot 'test-tui-pty.sh'
& bash $harness
exit $LASTEXITCODE
