<#
.SYNOPSIS
  Builds the Setup .exe for this PC's architecture from a Release build of the app.

.DESCRIPTION
  Run build.ps1 -Configuration Release first (with the same version fields and the update settings for a real release).
  Needs Inno Setup 6 (ISCC.exe): on PATH, or in its usual install folders. The result is
  out\release\PulseEightControl-Setup-<version>-<arch>.exe, named by the version people see (0.2.0-rc.1).

.EXAMPLE
  .\PulseEightControl-windows\build.ps1 -Configuration Release -Version 0.2.0-rc.1 -Build 0.2.0.201 -Channel rc -Label "Release Candidate 1"
  .\PulseEightControl-windows\installer\build-installer.ps1 -Version 0.2.0-rc.1 -Build 0.2.0.201
#>
param(
    # Must be what the app was built with (build.ps1 -Version and -Build). The defaults are a development build's (version.py dev).
    [string] $Version = '0.0.0-dev',
    [string] $Build = '0.0.0.0',
    # Accepted so the same set of values can be splatted to both scripts; the installer doesn't use them.
    [string] $Channel = 'dev',
    [string] $Label = 'Development build',
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

Write-Host "== Building the installer ($arch, version $Version, build $Build) with $iscc"
Invoke-Native $iscc "/DAppVersion=$Version" "/DAppBuild=$Build" "/DArch=$arch" "/DSourceDir=$sourceDir" "/DOutputDir=$release" (Join-Path $PSScriptRoot 'PulseEightControl.iss')
if ($LASTEXITCODE -ne 0) { throw 'ISCC failed' }

$setup = Join-Path $release "PulseEightControl-Setup-$Version-$arch.exe"
if (-not (Test-Path $setup)) { throw "Expected $setup but it was not produced." }
Write-Host "== Built: $setup"
