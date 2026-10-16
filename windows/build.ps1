<#
.SYNOPSIS
  Builds the shared core (Swift) and the Windows app (WinUI 3), then stages them side by side.

.EXAMPLE
  .\windows\build.ps1            # debug build for this PC's architecture
  .\windows\build.ps1 -Run       # build, then start the app
  .\windows\build.ps1 -Configuration Release
#>
param(
    [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Debug',
    [switch] $Run
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$platform = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' }
$swiftConfig = $Configuration.ToLower()
$native = Join-Path $PSScriptRoot "native\$platform"

Write-Host "== Building pulseeight_core (Swift, $swiftConfig)"
& swift build --package-path (Join-Path $root 'swift') -c $swiftConfig --product pulseeight_core
if ($LASTEXITCODE -ne 0) { throw 'swift build failed' }
$binPath = (& swift build --package-path (Join-Path $root 'swift') -c $swiftConfig --show-bin-path).Trim()

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
& dotnet build (Join-Path $PSScriptRoot 'PulseEightControl') -c $Configuration -p:Platform=$platform
if ($LASTEXITCODE -ne 0) { throw 'dotnet build failed' }

$exe = Join-Path $PSScriptRoot "PulseEightControl\bin\$platform\$Configuration\net8.0-windows10.0.19041.0\win-$($platform.ToLower())\PulseEightControl.exe"
Write-Host "== Built: $exe"
if ($Run) { & $exe }
