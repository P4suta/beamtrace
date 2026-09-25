# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.build'))
$dogfoodRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot "s3-dogfood-$PID"))
if (-not $dogfoodRoot.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe S3 dogfood directory: $dogfoodRoot"
}
$certRoot = Join-Path $dogfoodRoot 'certs'
$containerName = "beamtrace-s3-dogfood-$PID"
# renovate: datasource=docker depName=alpine/openssl
$opensslImage = 'alpine/openssl:3.5.7@sha256:19f8eb9004a1dbaec323eed6094e9b6bcc1dbf2697ecb5fb8d2fad4e3336a8f7'
# renovate: datasource=docker depName=versity/versitygw
$gatewayImage = 'versity/versitygw:v1.8.0@sha256:30292fc2eeacc67a36993b01f7a7a5e3361a19cced0e80c1d71cfa2a4b0a2499'
$accessKey = 'beamtrace-dogfood'
$secretKey = 'beamtrace-dogfood-only-2026'
$containerStarted = $false
$passed = $false

New-Item -ItemType Directory -Path $certRoot -Force | Out-Null
try {
    & docker run --rm --mount "type=bind,source=$certRoot,target=/certs" $opensslImage `
        req -x509 -nodes -newkey rsa:2048 -sha256 -days 1 `
        -keyout /certs/ca.key -out /certs/ca.crt `
        -subj '/CN=BeamTrace dogfood CA' `
        -addext 'basicConstraints=critical,CA:TRUE' `
        -addext 'keyUsage=critical,keyCertSign,cRLSign'
    if ($LASTEXITCODE -ne 0) { throw 'Could not generate the ephemeral S3 CA.' }
    & docker run --rm --mount "type=bind,source=$certRoot,target=/certs" $opensslImage `
        req -nodes -newkey rsa:2048 -sha256 `
        -keyout /certs/private.key -out /certs/server.csr `
        -subj /CN=localhost `
        -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' `
        -addext 'keyUsage=digitalSignature,keyEncipherment' `
        -addext 'extendedKeyUsage=serverAuth'
    if ($LASTEXITCODE -ne 0) { throw 'Could not generate the ephemeral S3 server key.' }
    & docker run --rm --mount "type=bind,source=$certRoot,target=/certs" $opensslImage `
        x509 -req -in /certs/server.csr -CA /certs/ca.crt -CAkey /certs/ca.key `
        -CAcreateserial -out /certs/public.crt -days 1 -sha256 -copy_extensions copy
    if ($LASTEXITCODE -ne 0) { throw 'Could not sign the ephemeral S3 TLS certificate.' }

    $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $portProbe.Start()
    $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()
    $endpoint = "https://127.0.0.1:$port"

    # VersityGW serves S3 over TLS with the ephemeral certificate and keeps objects on a tmpfs through its posix backend.
    # Credentials travel as environment variables so they stay out of the gateway's command line.
    & docker run --detach --rm --name $containerName `
        --publish "127.0.0.1:${port}:7070" `
        --env "ROOT_ACCESS_KEY_ID=$accessKey" `
        --env "ROOT_SECRET_ACCESS_KEY=$secretKey" `
        --mount "type=bind,source=$certRoot,target=/certs,readonly" `
        --tmpfs /data `
        $gatewayImage `
        --port ':7070' --region 'us-east-1' `
        --cert /certs/public.crt --key /certs/private.key `
        --health /health `
        posix /data
    if ($LASTEXITCODE -ne 0) { throw 'Could not start the S3-compatible TLS server.' }
    $containerStarted = $true

    $healthy = $false
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            $health = Invoke-WebRequest -Uri "$endpoint/health" -SkipCertificateCheck -TimeoutSec 2
            if ($health.StatusCode -eq 200) {
                $healthy = $true
                break
            }
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }
    if (-not $healthy) { throw 'S3-compatible TLS server did not become healthy.' }

    Push-Location (Join-Path $repoRoot 'packages/beamtrace_runtime')
    try {
        & gleam test --target erlang
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    finally {
        Pop-Location
    }

    $previousAccessKey = $env:AWS_ACCESS_KEY_ID
    $previousSecretKey = $env:AWS_SECRET_ACCESS_KEY
    $previousCaBundle = $env:AWS_CA_BUNDLE
    $previousEndpoint = $env:BEAMTRACE_S3_DOGFOOD_ENDPOINT
    try {
        $env:AWS_ACCESS_KEY_ID = $accessKey
        $env:AWS_SECRET_ACCESS_KEY = $secretKey
        $env:AWS_CA_BUNDLE = Join-Path $certRoot 'ca.crt'
        $env:BEAMTRACE_S3_DOGFOOD_ENDPOINT = $endpoint
        $runtimeEbin = Join-Path $repoRoot 'packages/beamtrace_runtime/build/dev/erlang/beamtrace_runtime/ebin'
        & erl -noshell -pa $runtimeEbin -eval 'case beamtrace_s3_dogfood_ffi:run() of ok -> halt(0); Other -> io:format("unexpected result: ~p~n", [Other]), halt(1) end.'
        if ($LASTEXITCODE -ne 0) { throw 'S3-compatible TLS round trip failed.' }
    }
    finally {
        $env:AWS_ACCESS_KEY_ID = $previousAccessKey
        $env:AWS_SECRET_ACCESS_KEY = $previousSecretKey
        $env:AWS_CA_BUNDLE = $previousCaBundle
        $env:BEAMTRACE_S3_DOGFOOD_ENDPOINT = $previousEndpoint
    }
    $passed = $true
}
finally {
    if ($containerStarted) {
        if (-not $passed) { & docker logs $containerName 2>&1 | Write-Warning }
        & docker rm --force $containerName | Out-Null
    }
    if (Test-Path -LiteralPath $dogfoodRoot -PathType Container) {
        Remove-Item -LiteralPath $dogfoodRoot -Recurse -Force
    }
}

Write-Host 'S3-compatible backend dogfood passed.'
exit 0
