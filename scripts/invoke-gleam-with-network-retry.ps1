# SPDX-License-Identifier: Apache-2.0 OR MIT

function Invoke-GleamWithNetworkRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(1, 5)][int] $MaximumAttempts = 3,
        [ValidateRange(0, 10000)][int] $RetryDelayMilliseconds = 2000
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $output = (& gleam @Arguments 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return [pscustomobject]@{
                ExitCode = 0
                Output = $output
            }
        }

        $gleamNetworkContext = $output -match '(?im)^\s*(?:error:\s*)?(?:A HTTP request failed|An error occurred while downloading|Failed to download|Unable to download|Dependency download failed|Package registry request failed)'
        $transientNetworkDiagnostic = $output -match '(?is)(error sending request for url|FailedToConnect|Posix\("nxdomain"\)|temporary failure in name resolution|failed to lookup address information|name or service not known|connection (reset|refused|closed)|operation timed out|request timed out|timeout was reached|unexpected end of file|HTTP[/ ][^\r\n]*(408|425|429|500|502|503|504))'
        $transientNetworkFailure = $gleamNetworkContext -and $transientNetworkDiagnostic
        if (-not $transientNetworkFailure -or $attempt -eq $MaximumAttempts) {
            return [pscustomobject]@{
                ExitCode = $exitCode
                Output = $output
            }
        }

        $nextAttempt = $attempt + 1
        Write-Warning "Transient Gleam registry/network failure; retrying attempt $nextAttempt of $MaximumAttempts."
        $delay = [int]($RetryDelayMilliseconds * [Math]::Pow(2, $attempt - 1))
        Start-Sleep -Milliseconds $delay
    }

    throw 'The bounded Gleam retry loop ended unexpectedly.'
}
