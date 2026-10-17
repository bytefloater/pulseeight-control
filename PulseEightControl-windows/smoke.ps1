<#
.SYNOPSIS
  Starts the fake matrix, launches the built Windows app against it, and fails if the app exits, hangs,
  never opens a window, never talks to the matrix, won't close when asked, or writes a crash log.

.DESCRIPTION
  A smoke test for what unit tests can't reach: the real WinUI app, its native core DLL and the Swift
  runtime, starting up and polling together. Uses a throwaway settings folder (P8_CONFIG_DIR) and the
  file secret store, so nothing touches your real settings.

  The WinUI app needs an interactive desktop session, so this runs on a developer machine and on
  GitHub's Windows runners, not in a service or SSH session.

.EXAMPLE
  .\PulseEightControl-windows\smoke.ps1                      # build (debug), then watch the app for 15 s
  .\PulseEightControl-windows\smoke.ps1 -NoBuild -Seconds 30
  .\PulseEightControl-windows\smoke.ps1 -Configuration Release
#>
param(
    [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Debug',
    [int] $Seconds = 15,
    [switch] $NoBuild
)

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $NoBuild) { & (Join-Path $PSScriptRoot 'build.ps1') -Configuration $Configuration }

$exe = Join-Path $out "windows\bin\PulseEightControl\$($Configuration.ToLower())_win-$($platform.ToLower())\PulseEightControl.exe"
if (-not (Test-Path $exe)) { throw "The app isn't built: $exe (run build.ps1, or drop -NoBuild)" }

Write-Host '== Building the fake matrix (p8fake)'
$fakePackage = Join-Path $root 'PulseEightFakeServer'
$fakeScratch = Join-Path $out 'fake'
Invoke-Native swift build --package-path $fakePackage --scratch-path $fakeScratch --product p8fake
if ($LASTEXITCODE -ne 0) { throw 'swift build (p8fake) failed' }
$fakeBin = (Invoke-Native swift build --package-path $fakePackage --scratch-path $fakeScratch --show-bin-path | Select-Object -Last 1).ToString().Trim()
$fakeExe = Join-Path $fakeBin 'p8fake.exe'
if (-not (Test-Path $fakeExe)) { throw "p8fake wasn't built: $fakeExe" }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('p8-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $work | Out-Null
$fakeLog = Join-Path $work 'fake.log'
$fakeErr = Join-Path $work 'fake.err'
$config = Join-Path $work 'config'
New-Item -ItemType Directory -Force $config | Out-Null

$fake = $null
$app = $null
$failures = @()

try {
    Write-Host '== Starting p8fake on a free port'
    # No --quiet: each request is logged, which is how we know the app really talked to it.
    $fake = Start-Process -FilePath $fakeExe -ArgumentList '--port', '0', '--password', 'secret' `
        -RedirectStandardOutput $fakeLog -RedirectStandardError $fakeErr -PassThru -WindowStyle Hidden

    $port = $null
    for ($i = 0; $i -lt 100 -and -not $port; $i++) {
        if ($fake.HasExited) { throw "p8fake exited early: $(Get-Content $fakeErr -Raw)" }
        if (Test-Path $fakeLog) {
            # The file starts out empty, and then Get-Content -Raw gives nothing at all (not even an empty string).
            $text = Get-Content $fakeLog -Raw
            if ($text) {
                $match = [regex]::Match($text, 'http://[^:\s]+:(\d+)')
                if ($match.Success) { $port = [int] $match.Groups[1].Value }
            }
        }
        if (-not $port) { Start-Sleep -Milliseconds 100 }
    }
    if (-not $port) { throw 'p8fake never reported its port' }
    Write-Host "   listening on 127.0.0.1:$port"

    # Written without a byte-order mark: the core's JSON reader won't accept one.
    $settings = @{ matrix = @{ host = '127.0.0.1'; port = $port; timeout = 3; poll_interval = 1; detail_poll_interval = 1 } } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText((Join-Path $config 'settings.json'), $settings, (New-Object System.Text.UTF8Encoding($false)))

    $crashLog = Join-Path $env:LOCALAPPDATA 'PulseEightControl\crash.log'
    $crashBefore = $null
    if (Test-Path $crashLog) { $crashBefore = (Get-Item $crashLog).LastWriteTimeUtc }

    Write-Host "== Launching the app and watching it for $Seconds s"
    $env:P8_CONFIG_DIR = $config
    $env:P8_SECRET_STORE = 'file'
    try { $app = Start-Process -FilePath $exe -PassThru }
    finally { Remove-Item Env:P8_CONFIG_DIR, Env:P8_SECRET_STORE -ErrorAction SilentlyContinue }

    $sawWindow = $false
    $started = Get-Date
    while (((Get-Date) - $started).TotalSeconds -lt $Seconds) {
        Start-Sleep -Milliseconds 500
        $app.Refresh()
        if ($app.HasExited) {
            $failures += "The app exited after $([int] ((Get-Date) - $started).TotalSeconds) s with code $($app.ExitCode)"
            break
        }
        if ($app.MainWindowHandle -ne [IntPtr]::Zero) { $sawWindow = $true }
    }

    if (-not $app.HasExited) {
        if (-not $sawWindow) { $failures += 'The app never opened a window' }
        if (-not $app.Responding) { $failures += 'The app stopped responding' }

        $polls = 0
        if (Test-Path $fakeLog) { $polls = @(Select-String -Path $fakeLog -Pattern 'GET /Port/List' -SimpleMatch -ErrorAction SilentlyContinue).Count }
        if ($polls -lt 2) { $failures += "The app polled the fake matrix $polls time(s); it should have connected and polled repeatedly" }

        Write-Host '== Closing the app'
        [void] $app.CloseMainWindow()
        if (-not $app.WaitForExit(10000)) {
            $failures += 'The app did not close when asked'
            $app.Kill()
        }
    }

    if (Test-Path $crashLog) {
        $crashAfter = (Get-Item $crashLog).LastWriteTimeUtc
        if ($null -eq $crashBefore -or $crashAfter -gt $crashBefore) {
            $failures += "The app wrote a crash log: $crashLog`n$(Get-Content $crashLog -Raw)"
        }
    }
}
finally {
    if ($app -and -not $app.HasExited) { $app.Kill() }
    if ($fake -and -not $fake.HasExited) { $fake.Kill() }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'Smoke test passed: the app opened, connected to the fake matrix and closed cleanly.'
