<#
.SYNOPSIS
  Installs PulseEight Control as a real Windows service using NSSM, so it
  starts automatically on boot (before any user logs in) and restarts itself
  if it crashes.

.DESCRIPTION
  Requires NSSM (https://nssm.cc). By default this script looks for it on
  PATH (or at the literal path given via -NssmPath) and stops with an error
  telling you to install it, or to re-run with -InstallNssm, if it can't be
  found. Pass -InstallNssm to have the script download and unpack NSSM
  itself into scripts\windows\tools instead of installing it yourself.

  Requires the app's virtual environment to already exist - see the "Setup"
  section in the repo's README.md. Run this script itself from an elevated
  (Administrator) PowerShell prompt.

.EXAMPLE
  .\install-service.ps1 -InstallNssm

.EXAMPLE
  .\install-service.ps1 -AddFirewallRule

.EXAMPLE
  .\install-service.ps1 -Port 9000 -NssmPath "C:\tools\nssm-2.24\win64\nssm.exe" -AddFirewallRule
#>

param(
    [string]$ServiceName = "PulseEightControl",
    [string]$NssmPath = "nssm",
    [int]$Port = 8000,
    [switch]$AddFirewallRule,
    [switch]$InstallNssm
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$BackendDir = Join-Path $RepoRoot "backend"
$PythonExe = Join-Path $RepoRoot ".venv\Scripts\python.exe"
$ConfigPath = Join-Path $BackendDir "config.json"
$LogPath = Join-Path $RepoRoot "service.log"

function Find-Nssm {
    param([string]$PathOrCommand)

    $onPath = Get-Command $PathOrCommand -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    if (Test-Path $PathOrCommand -PathType Leaf) { return (Resolve-Path $PathOrCommand).Path }
    return $null
}

function Install-Nssm {
    param([string]$RepoRoot)

    $version = "2.24"
    $toolsDir = Join-Path $RepoRoot "scripts\windows\tools"
    $zipPath = Join-Path $env:TEMP "nssm-$version.zip"
    $arch = if ([Environment]::Is64BitOperatingSystem) { "win64" } else { "win32" }
    $exePath = Join-Path $toolsDir "nssm-$version\$arch\nssm.exe"

    if (Test-Path $exePath) { return $exePath }

    Write-Host "Downloading NSSM $version..."
    New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $prevProgressPreference = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-$version.zip" -OutFile $zipPath
    } finally {
        $ProgressPreference = $prevProgressPreference
    }
    Expand-Archive -Path $zipPath -DestinationPath $toolsDir -Force
    Remove-Item $zipPath -Force

    if (-not (Test-Path $exePath)) {
        Write-Error "Downloaded NSSM but didn't find nssm.exe at the expected path: $exePath`nThe zip layout may have changed - check $toolsDir and pass -NssmPath to point at it directly."
    }
    Write-Host "NSSM installed at $exePath"
    return $exePath
}

$resolvedNssm = Find-Nssm $NssmPath
if (-not $resolvedNssm) {
    if ($InstallNssm) {
        $resolvedNssm = Install-Nssm $RepoRoot
    } else {
        Write-Error "NSSM was not found (looked for '$NssmPath' on PATH and as a file path).`nEither install it yourself (e.g. 'choco install nssm -y') and pass -NssmPath if it's not on PATH afterwards, or re-run this script with -InstallNssm to have it downloaded automatically."
    }
}
$NssmPath = $resolvedNssm

if (-not (Test-Path $PythonExe)) {
    Write-Error "Virtual environment not found at '$PythonExe'.`nRun this first, from the repo root:`n  python -m venv .venv`n  .venv\Scripts\pip install -r backend\requirements.txt"
}

if (-not (Test-Path $ConfigPath)) {
    Write-Warning "backend\config.json not found. Copy backend\config.example.json to backend\config.json and set your matrix's host before starting the service."
}

Write-Host "Installing service '$ServiceName'..."
& $NssmPath install $ServiceName $PythonExe "-m uvicorn app.main:app --host 0.0.0.0 --port $Port"
& $NssmPath set $ServiceName AppDirectory $BackendDir
& $NssmPath set $ServiceName DisplayName "PulseEight Control"
& $NssmPath set $ServiceName Description "Web app for controlling a Pulse-Eight NeoMatrix"
& $NssmPath set $ServiceName Start SERVICE_AUTO_START
& $NssmPath set $ServiceName AppStdout $LogPath
& $NssmPath set $ServiceName AppStderr $LogPath
& $NssmPath set $ServiceName AppRotateFiles 1
& $NssmPath set $ServiceName AppRotateBytes 1048576
& $NssmPath set $ServiceName AppExit Default Restart
& $NssmPath set $ServiceName AppRestartDelay 5000

Write-Host "Starting service..."
& $NssmPath start $ServiceName

if ($AddFirewallRule) {
    Write-Host "Adding firewall rule '$ServiceName' (inbound, TCP $Port, allow)..."
    if (Get-NetFirewallRule -DisplayName $ServiceName -ErrorAction SilentlyContinue) {
        Write-Host "Firewall rule '$ServiceName' already exists; leaving it as-is."
    } else {
        New-NetFirewallRule -DisplayName $ServiceName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
        Write-Host "Firewall rule added."
    }
}

Write-Host ""
Write-Host "Done. Open http://localhost:$Port to confirm it's running."
Write-Host "Logs:   $LogPath"
Write-Host "Status: nssm status $ServiceName"
Write-Host "Stop:   nssm stop $ServiceName"
Write-Host "Remove: .\uninstall-service.ps1"

if (-not $AddFirewallRule) {
    Write-Host ""
    Write-Host "If other devices on your network need to reach it, allow inbound" -ForegroundColor Yellow
    Write-Host "traffic on TCP port $Port in Windows Defender Firewall - services" -ForegroundColor Yellow
    Write-Host "run with no interactive session, so the usual first-run firewall" -ForegroundColor Yellow
    Write-Host "prompt never appears. Re-run this script with -AddFirewallRule to" -ForegroundColor Yellow
    Write-Host "do that automatically." -ForegroundColor Yellow
}
