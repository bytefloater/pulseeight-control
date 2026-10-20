<#
.SYNOPSIS
  Builds the shared core (Swift) and the Windows app (WinUI 3), then stages them side by side.

.DESCRIPTION
  Everything is built under <repo>\out (short paths: WinUI's packaging tools can't cope with long
  ones): out\kit (Swift), out\native\<arch> (the core DLL and Swift runtime), out\windows (.NET).
  Delete out\ for a completely clean build.

.EXAMPLE
  .\PulseEightControl-windows\build.ps1            # debug build for this PC's architecture
  .\PulseEightControl-windows\build.ps1 -Run       # build, then start the app
  .\PulseEightControl-windows\build.ps1 -Configuration Release

.EXAMPLE
  # A release build. The four version values come from the release tag (python3 scripts/release/version.py fields v0.2.0.rc-01),
  # then where the feed is and the key it must be signed with.
  .\PulseEightControl-windows\build.ps1 -Configuration Release -Version 0.2.0-rc.1 -Build 0.2.0.201 `
      -Channel rc -Label "Release Candidate 1" -UpdateBaseUrl https://example.github.io/releases -UpdatePublicKey <base64>
#>
param(
    [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Debug',
    [switch] $Run,
    # The release's version fields, from its tag (scripts/release/version.py). The defaults are a development build's
    # (version.py dev); test_version.py checks they match. -Version is what people see; -Build is what the update feed compares
    # (sparkle:version), derived from the tag so it always rises with the release.
    [string] $Version = '0.0.0-dev',
    [string] $Build = '0.0.0.0',
    [string] $Channel = 'dev',
    [string] $Label = 'Development build',
    # Compiled in only when both are given; a build without them never checks for updates.
    [string] $UpdateBaseUrl = '',
    [string] $UpdatePublicKey = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')
$swiftConfig = $Configuration.ToLower()

Write-Host "== Building pulseeight_core (Swift, $swiftConfig)"
$kit = Join-Path $root 'PulseEightKit'
$scratch = Join-Path $out 'kit'
Invoke-Native swift build --package-path $kit --scratch-path $scratch -c $swiftConfig --product pulseeight_core
if ($LASTEXITCODE -ne 0) { throw 'swift build failed' }
$binPath = (Invoke-Native swift build --package-path $kit --scratch-path $scratch -c $swiftConfig --show-bin-path | Select-Object -Last 1).ToString().Trim()

New-Item -ItemType Directory -Force $native | Out-Null
Copy-Item (Join-Path $binPath 'pulseeight_core.dll') $native -Force

# The DLL needs the Swift runtime (swiftCore.dll, Foundation.dll, ...) beside it. The Swift
# installer puts those under %LOCALAPPDATA%\Programs\Swift\Runtimes\<version>\usr\bin.
$runtimeDirs = @()
$runtimeDirs += Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Swift\Runtimes') -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'usr\bin' }
$swiftc = Get-Command swiftc -ErrorAction SilentlyContinue
if ($swiftc) { $runtimeDirs += Split-Path $swiftc.Source }
$runtime = $runtimeDirs | Where-Object { Test-Path (Join-Path $_ 'swiftCore.dll') } | Select-Object -First 1
if (-not $runtime) { throw 'Could not find the Swift runtime DLLs (swiftCore.dll). Is Swift installed?' }
Write-Host "== Copying Swift runtime from $runtime"
Get-ChildItem $runtime -Filter '*.dll' | Copy-Item -Destination $native -Force

Write-Host "== Building the Windows app ($Configuration, $platform)"
$update = @()
if ($UpdateBaseUrl -or $UpdatePublicKey) {
    if (-not ($UpdateBaseUrl -and $UpdatePublicKey)) { throw 'Give both -UpdateBaseUrl and -UpdatePublicKey, or neither.' }
    $update = @("-p:P8UpdateBaseUrl=$UpdateBaseUrl", "-p:P8UpdatePublicKey=$UpdatePublicKey")
}
Invoke-Native dotnet build (Join-Path $PSScriptRoot 'App') -c $Configuration "-p:Platform=$platform" "-p:P8Version=$Version" "-p:P8Build=$Build" "-p:P8Channel=$Channel" "-p:P8Label=$Label" @update
if ($LASTEXITCODE -ne 0) { throw 'dotnet build failed' }

$exe = Join-Path $out "windows\bin\PulseEightControl\$($Configuration.ToLower())_win-$($platform.ToLower())\PulseEightControl.exe"
Write-Host "== Built: $exe"
if ($Run) { & $exe }
