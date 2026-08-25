# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $BeamTraceArguments
)

$ErrorActionPreference = 'Stop'
$installRoot = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $installRoot 'runtime'
$ertsDirectories = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -Filter 'erts-*')
if ($ertsDirectories.Count -ne 1) {
    throw "BeamTrace archive must contain exactly one ERTS runtime, found $($ertsDirectories.Count)."
}
$escript = Join-Path $ertsDirectories[0].FullName 'bin/escript.exe'
if (-not (Test-Path -LiteralPath $escript -PathType Leaf)) {
    throw "Bundled escript executable is missing: $escript"
}
$previousAgent = $env:BEAMTRACE_AGENT_BEAM
$previousWeb = $env:BEAMTRACE_WEB_ROOT
$previousErlLibs = $env:ERL_LIBS
$previousErlRoot = $env:ERL_ROOTDIR
$previousRoot = $env:ROOTDIR
$runtimeEnvironmentNames = @('PATH', 'BINDIR', 'EMU', 'PROGNAME', 'ESCRIPT_NAME')
$previousRuntimeEnvironment = @{}
$previousRuntimeMarkers = @{}
foreach ($name in $runtimeEnvironmentNames) {
    $previousRuntimeEnvironment[$name] = [pscustomobject]@{
        IsSet = Test-Path "Env:$name"
        Value = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    foreach ($marker in @("BEAMTRACE_PARENT_${name}_SET", "BEAMTRACE_PARENT_$name")) {
        $previousRuntimeMarkers[$marker] = [pscustomobject]@{
            IsSet = Test-Path "Env:$marker"
            Value = [Environment]::GetEnvironmentVariable($marker, 'Process')
        }
    }
}
$previousBundledRuntime = $env:BEAMTRACE_BUNDLED_RUNTIME
$previousParentErlRootSet = $env:BEAMTRACE_PARENT_ERL_ROOTDIR_SET
$previousParentErlRoot = $env:BEAMTRACE_PARENT_ERL_ROOTDIR
$previousParentRootSet = $env:BEAMTRACE_PARENT_ROOTDIR_SET
$previousParentRoot = $env:BEAMTRACE_PARENT_ROOTDIR
$previousParentErlLibsSet = $env:BEAMTRACE_PARENT_ERL_LIBS_SET
$previousParentErlLibs = $env:BEAMTRACE_PARENT_ERL_LIBS
$hadErlLibs = Test-Path Env:ERL_LIBS
$hadErlRoot = Test-Path Env:ERL_ROOTDIR
$hadRoot = Test-Path Env:ROOTDIR
try {
    $env:BEAMTRACE_AGENT_BEAM = Join-Path $installRoot 'lib/beamtrace_agent.beam'
    $env:BEAMTRACE_WEB_ROOT = Join-Path $installRoot 'share/beamtrace/web'
    $env:BEAMTRACE_BUNDLED_RUNTIME = '1'
    foreach ($name in $runtimeEnvironmentNames) {
        $saved = $previousRuntimeEnvironment[$name]
        [Environment]::SetEnvironmentVariable(
            "BEAMTRACE_PARENT_${name}_SET",
            $(if ($saved.IsSet) { '1' } else { '0' }),
            'Process'
        )
        [Environment]::SetEnvironmentVariable(
            "BEAMTRACE_PARENT_$name",
            $(if ($saved.IsSet) { $saved.Value } else { $null }),
            'Process'
        )
    }
    $env:BEAMTRACE_PARENT_ERL_ROOTDIR_SET = if ($hadErlRoot) { '1' } else { '0' }
    $env:BEAMTRACE_PARENT_ERL_ROOTDIR = if ($hadErlRoot) { $previousErlRoot } else { $null }
    $env:BEAMTRACE_PARENT_ROOTDIR_SET = if ($hadRoot) { '1' } else { '0' }
    $env:BEAMTRACE_PARENT_ROOTDIR = if ($hadRoot) { $previousRoot } else { $null }
    $env:BEAMTRACE_PARENT_ERL_LIBS_SET = if ($hadErlLibs) { '1' } else { '0' }
    $env:BEAMTRACE_PARENT_ERL_LIBS = if ($hadErlLibs) { $previousErlLibs } else { $null }
    $nativeRoot = Join-Path $installRoot 'lib/native'
    $env:ERL_LIBS = if ([string]::IsNullOrEmpty($previousErlLibs)) {
        $nativeRoot
    }
    else {
        "$nativeRoot$([IO.Path]::PathSeparator)$previousErlLibs"
    }
    $env:ERL_ROOTDIR = $runtimeRoot
    $env:ROOTDIR = $runtimeRoot
    & $escript (Join-Path $installRoot 'lib/beamtrace.escript') @BeamTraceArguments
    $exitCode = $LASTEXITCODE
}
finally {
    $env:BEAMTRACE_AGENT_BEAM = $previousAgent
    $env:BEAMTRACE_WEB_ROOT = $previousWeb
    $env:ERL_LIBS = $previousErlLibs
    $env:ERL_ROOTDIR = $previousErlRoot
    $env:ROOTDIR = $previousRoot
    $env:BEAMTRACE_BUNDLED_RUNTIME = $previousBundledRuntime
    foreach ($entry in $previousRuntimeMarkers.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable(
            $entry.Key,
            $(if ($entry.Value.IsSet) { $entry.Value.Value } else { $null }),
            'Process'
        )
    }
    $env:BEAMTRACE_PARENT_ERL_ROOTDIR_SET = $previousParentErlRootSet
    $env:BEAMTRACE_PARENT_ERL_ROOTDIR = $previousParentErlRoot
    $env:BEAMTRACE_PARENT_ROOTDIR_SET = $previousParentRootSet
    $env:BEAMTRACE_PARENT_ROOTDIR = $previousParentRoot
    $env:BEAMTRACE_PARENT_ERL_LIBS_SET = $previousParentErlLibsSet
    $env:BEAMTRACE_PARENT_ERL_LIBS = $previousParentErlLibs
}

exit $exitCode
