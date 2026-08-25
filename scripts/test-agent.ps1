# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [ValidateSet('short', 'long', 'tls')]
    [string] $Distribution = 'short'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repoRoot ".build/agent-$Distribution"
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
$runtimeRoot = Join-Path $repoRoot 'packages/beamtrace_runtime'

Push-Location $runtimeRoot
try {
    & gleam build --target erlang
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
}

$runtimeCodePaths = @(
    Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'build/dev/erlang') -Directory |
        ForEach-Object { Join-Path $_.FullName 'ebin' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container }
)
foreach ($requiredModule in @(
    'beamtrace_runtime@credit_policy.beam',
    'beamtrace_runtime@crypto.beam'
)) {
    if (-not ($runtimeCodePaths | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ $requiredModule) -PathType Leaf
    })) {
        throw "Runtime dependency module was not built for the agent tests: $requiredModule"
    }
}

$sources = @(
    (Join-Path $repoRoot 'agent\src\beamtrace_agent.erl'),
    (Join-Path $repoRoot 'packages\beamtrace_runtime\src\beamtrace_relay.erl'),
    (Join-Path $repoRoot 'packages\beamtrace_runtime\src\beamtrace_capture_ffi.erl'),
    (Join-Path $repoRoot 'agent\test\beamtrace_test_peer.erl'),
    (Join-Path $repoRoot 'agent\test\beamtrace_agent_fixture.erl'),
    (Join-Path $repoRoot 'agent\test\beamtrace_agent_tests.erl'),
    (Join-Path $repoRoot 'agent\test\beamtrace_relay_tests.erl'),
    (Join-Path $repoRoot 'agent\test\beamtrace_capture_tests.erl'),
    (Join-Path $repoRoot 'agent\test\beamtrace_live_tests.erl'),
    (Join-Path $repoRoot 'agent\test\beamtrace_distributed_tests.erl')
)

& erlc +debug_info -Werror -o $buildDir $sources
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$previousErlAflags = $env:ERL_AFLAGS
try {
    if ($Distribution -eq 'long') {
        $nameArguments = @('-name', 'beamtrace_relay_test_long@127.0.0.1')
    }
    else {
        $nameArguments = @('-sname', "beamtrace_relay_test_$Distribution")
    }

    if ($Distribution -eq 'tls') {
        $openssl = Get-Command openssl -ErrorAction SilentlyContinue
        if ($null -eq $openssl) {
            throw 'OpenSSL is required for the TLS distribution test.'
        }
        $tlsDir = Join-Path $buildDir 'tls'
        New-Item -ItemType Directory -Path $tlsDir -Force | Out-Null
        $certificate = Join-Path $tlsDir 'certificate.pem'
        $privateKey = Join-Path $tlsDir 'private-key.pem'
        & openssl req -x509 -newkey rsa:2048 -nodes -days 1 `
            -subj '/CN=localhost' `
            -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' `
            -keyout $privateKey -out $certificate
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

        $certificatePath = $certificate.Replace('\', '/')
        $privateKeyPath = $privateKey.Replace('\', '/')
        $tlsConfig = Join-Path $tlsDir 'ssl_dist.conf'
        @"
[
 {server,[{certfile,"$certificatePath"},{keyfile,"$privateKeyPath"},{verify,verify_none}]},
 {client,[{certfile,"$certificatePath"},{keyfile,"$privateKeyPath"},{verify,verify_none}]}
].
"@ | Set-Content -LiteralPath $tlsConfig -Encoding utf8NoBOM
        $tlsConfigPath = $tlsConfig.Replace('\', '/')
        $env:ERL_AFLAGS = "-proto_dist inet_tls -ssl_dist_optfile $tlsConfigPath"
    }

    & erl -noshell @nameArguments -setcookie beamtrace_test_cookie `
        -pa $buildDir @runtimeCodePaths `
        -eval 'case eunit:test([beamtrace_agent_tests, beamtrace_relay_tests, beamtrace_capture_tests, beamtrace_live_tests, beamtrace_distributed_tests], [verbose]) of ok -> halt(0); _ -> halt(1) end.'
    exit $LASTEXITCODE
}
finally {
    $env:ERL_AFLAGS = $previousErlAflags
}
