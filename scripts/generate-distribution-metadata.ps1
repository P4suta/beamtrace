# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Version,
    [Parameter(Mandatory = $true)]
    [string] $BaseUrl,
    [Parameter(Mandatory = $true)]
    [string] $Homepage,
    [Parameter(Mandatory = $true)]
    [string] $ChecksumsPath,
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') {
    throw "Invalid release version: $Version"
}
$releaseUri = [Uri]$BaseUrl
if (-not $releaseUri.IsAbsoluteUri -or $releaseUri.Scheme -ne 'https' -or -not [string]::IsNullOrEmpty($releaseUri.UserInfo) -or -not [string]::IsNullOrEmpty($releaseUri.Query) -or -not [string]::IsNullOrEmpty($releaseUri.Fragment)) {
    throw 'BaseUrl must be an HTTPS URL without credentials, query, or fragment.'
}
$homepageUri = [Uri]$Homepage
if (-not $homepageUri.IsAbsoluteUri -or $homepageUri.Scheme -ne 'https' -or -not [string]::IsNullOrEmpty($homepageUri.UserInfo) -or -not [string]::IsNullOrEmpty($homepageUri.Query) -or -not [string]::IsNullOrEmpty($homepageUri.Fragment)) {
    throw 'Homepage must be an HTTPS URL without credentials, query, or fragment.'
}
if (-not (Test-Path -LiteralPath $ChecksumsPath -PathType Leaf)) {
    throw "Checksum inventory does not exist: $ChecksumsPath"
}
$checksums = Get-Content -Raw -LiteralPath $ChecksumsPath | ConvertFrom-Json -AsHashtable
$base = $BaseUrl.TrimEnd('/')

function Artifact([string] $Platform, [string] $Architecture) {
    "beamtrace-$Version-$Platform-$Architecture.zip"
}

function Digest([string] $Name) {
    if (-not $checksums.ContainsKey($Name)) {
        throw "Checksum inventory is missing $Name"
    }
    $value = [string]$checksums[$Name]
    if ($value -notmatch '^[0-9a-f]{64}$') {
        throw "Invalid SHA-256 for $Name"
    }
    $value
}

$macArm = Artifact 'macos' 'arm64'
$macX64 = Artifact 'macos' 'x64'
$linuxArm = Artifact 'linux' 'arm64'
$linuxX64 = Artifact 'linux' 'x64'
$windowsArm = Artifact 'windows' 'arm64'
$windowsX64 = Artifact 'windows' 'x64'

$formula = @"
# SPDX-License-Identifier: Apache-2.0 OR MIT
class BeamTrace < Formula
  desc "Causal workbench for Gleam, Elixir, and Erlang systems"
  homepage "$($Homepage.TrimEnd('/'))"
  version "$Version"
  license any_of: ["Apache-2.0", "MIT"]

  on_macos do
    if Hardware::CPU.arm?
      url "$base/$macArm"
      sha256 "$(Digest $macArm)"
    else
      url "$base/$macX64"
      sha256 "$(Digest $macX64)"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "$base/$linuxArm"
      sha256 "$(Digest $linuxArm)"
    else
      url "$base/$linuxX64"
      sha256 "$(Digest $linuxX64)"
    end
  end

  def install
    libexec.install Dir["*"]
    chmod 0755, libexec/"bin/beamtrace"
    bin.install_symlink libexec/"bin/beamtrace"
  end

  test do
    assert_match "beamtrace $Version", shell_output("#{bin}/beamtrace version")
  end
end
"@

$scoop = [ordered]@{
    version = $Version
    description = 'Causal workbench for Gleam, Elixir, and Erlang systems'
    homepage = $Homepage.TrimEnd('/')
    license = 'Apache-2.0 OR MIT'
    architecture = [ordered]@{
        '64bit' = [ordered]@{
            url = "$base/$windowsX64"
            hash = Digest $windowsX64
        }
        arm64 = [ordered]@{
            url = "$base/$windowsArm"
            hash = Digest $windowsArm
        }
    }
    bin = @(, @('bin/beamtrace.ps1', 'beamtrace'))
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$formula | Set-Content -LiteralPath (Join-Path $resolvedOutput 'beamtrace.rb') -Encoding utf8NoBOM
$scoop | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resolvedOutput 'beamtrace.json') -Encoding utf8NoBOM
exit 0
