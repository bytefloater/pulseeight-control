<#
.SYNOPSIS
  Builds the Setup .exe for this PC's architecture from a Release build of the app.

.DESCRIPTION
  Run build.ps1 -Configuration Release first (with -Version and the update settings for a real release).
  Needs Inno Setup 6 (ISCC.exe): on PATH, or in its usual install folders. The result is
  out\release\PulseEightControl-Setup-<version>-<arch>.exe.

.EXAMPLE
  .\PulseEightControl-windows\build.ps1 -Configuration Release -Version 0.1.0.7
  .\PulseEightControl-windows\installer\build-installer.ps1 -Version 0.1.0.7
#>
param(
    # Must be the version the app was built with (build.ps1 -Version): the feed compares against it.
    [string] $Version = '0.1.0.0',
    [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Release'
)

. (Join-Path $PSScriptRoot '..\common.ps1')
$arch = $platform.ToLower()

$sourceDir = Join-Path $out "windows\bin\PulseEightControl\$($Configuration.ToLower())_win-$arch"
if (-not (Test-Path (Join-Path $sourceDir 'PulseEightControl.exe'))) {
    throw "No build at $sourceDir. Run build.ps1 -Configuration $Configuration first."
}

$candidates = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue | ForEach-Object { $_.Source }),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
) | Where-Object { $_ -and (Test-Path $_) }
$iscc = $candidates | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) was not found. Install it from https://jrsoftware.org/isinfo.php' }

$release = Join-Path $out 'release'
New-Item -ItemType Directory -Force $release | Out-Null

Write-Host "== Building the installer ($arch, version $Version) with $iscc"
Invoke-Native $iscc "/DAppVersion=$Version" "/DArch=$arch" "/DSourceDir=$sourceDir" "/DOutputDir=$release" (Join-Path $PSScriptRoot 'PulseEightControl.iss')
if ($LASTEXITCODE -ne 0) { throw 'ISCC failed' }

$setup = Join-Path $release "PulseEightControl-Setup-$Version-$arch.exe"
if (-not (Test-Path $setup)) { throw "Expected $setup but it was not produced." }
Write-Host "== Built: $setup"
