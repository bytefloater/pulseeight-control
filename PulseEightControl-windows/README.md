# PulseEight Control for Windows

A native WinUI 3 app. The interface is written in C#; everything that talks to the matrix
(connection, polling, settings, the admin password, validation, every command and all user-visible
text) is the shared Swift core in `../PulseEightKit`, loaded as `pulseeight_core.dll` and driven with
JSON. See `../docs/core-interface.md` and `../docs/localisation.md`.

| Project | What it is |
|---|---|
| `Core` (`PulseEight.Core`) | Managed wrapper over the C interface (`CoreClient`, snapshot types). No UI, builds on any OS. |
| `Core.Tests` | xUnit tests; the end-to-end ones run against the real library and the Swift fake matrix (`../PulseEightFakeServer`). |
| `Updates` (`PulseEight.Updates`) | The updater without any UI: reads a signed feed, downloads and verifies an update, runs its installer (NetSparkle's core). Builds on any OS. |
| `Updates.Tests` | xUnit tests with a local signed feed and download server; they run on any OS and need no matrix. |
| `App` (`PulseEightControl`) | The WinUI 3 app. The interface is built in code; the only XAML is `App.xaml`, which WinUI needs to load its control styles. |

## The logo

`App/Assets/Logo.png` (1024 px) is the logo. `App/Assets/AppIcon.ico` is built from it by `App/Assets/make-icon.py` (macOS;
re-run it and commit the result when the logo changes). The icon is the `.exe`'s (`ApplicationIcon` in the project file: Explorer,
the taskbar, shortcuts) and the installer's (`SetupIconFile`); both files are also copied beside the `.exe` so the window, the
title bar and the About page can load them.

## Build and run

Needs the Swift toolchain and the .NET 8 (or newer) SDK.

```powershell
.\PulseEightControl-windows\build.ps1 -Run
```

That builds `pulseeight_core.dll`, stages it with the Swift runtime DLLs, builds the app
(self-contained: no Windows App Runtime install needed) and starts it. Crashes are written to
`%LOCALAPPDATA%\PulseEightControl\crash.log`.

All build output goes under `out\` at the repository root, to keep paths short (WinUI's packaging
tools can't handle long ones):

| Folder | Holds |
|---|---|
| `out\kit` | the Swift build of `PulseEightKit` (`--scratch-path`) |
| `out\native\<arch>` | `pulseeight_core.dll` and the Swift runtime DLLs it needs |
| `out\windows` | the .NET build (`UseArtifactsOutput`, see `Directory.Build.props`): `bin\<project>\<config>_<runtime>\` |
| `out\fake` | optional: the fake matrix, if you build it there (below) |

The app is `out\windows\bin\PulseEightControl\debug_win-arm64\PulseEightControl.exe`
(`win-x64` on Intel/AMD). Delete `out\` for a completely clean build.

## Without a matrix

Run the fake one and use `127.0.0.1`, port `8080` in Settings:

```powershell
swift run --package-path PulseEightFakeServer p8fake --port 8080 --password secret
```

## Tests

```powershell
swift build --package-path PulseEightFakeServer --scratch-path out/fake --product p8fake
$env:P8_CORE_LIBRARY = "$PWD\out\native\ARM64\pulseeight_core.dll"   # staged by build.ps1
dotnet test PulseEightControl-windows\Core.Tests
```

The end-to-end tests start `p8fake` themselves (from `out\fake`, or the package's own `.build`;
set `P8_FAKE_SERVER` to use another executable) and give the core a scratch settings folder, so your
real settings aren't touched. Without `P8_CORE_LIBRARY` they are skipped.

### Smoke test of the app itself

`Core.Tests` exercise the core through the C interface. `smoke.ps1` runs the real WinUI app:

```powershell
.\PulseEightControl-windows\smoke.ps1                  # builds (debug), then watches the app for 15 s
.\PulseEightControl-windows\smoke.ps1 -NoBuild -Seconds 30
```

It starts `p8fake` on a free port, launches the app against it with a throwaway settings folder, and
fails if the app exits, never opens a window, stops responding, never polls the fake, won't close when
asked, or writes `crash.log`. It needs an interactive desktop session (not SSH or a service).

## Notes

* The WinUI project needs the Windows XAML tooling, so it can only be built on Windows; `Core` and
  `Core.Tests` build anywhere (on macOS use `libpulseeight_core.dylib`, and `DOTNET_ROLL_FORWARD=Major`
  if only a newer .NET runtime is installed).
* Where text comes from: `Loc.T("key")` reads the table the core serves for the language in force;
  Settings > Language switches it. See `../docs/localisation.md`.
* Several matrices: Settings > Connections lists them (the tick shows one, Edit changes it, Add matrix adds one, and the dialog's Find asks gotomymatrix.com which matrix is on the network); the chooser at the top of the navigation pane switches between them. Each has its own timings and admin password. The Hardware page is a list of topics in the style of Windows Settings (System, Features, Health, Diagnostics, Front panel, Firmware updates, Inputs, Outputs), each opening its own page with a back button (also Alt+Left). Maintenance (admin password only) restarts the matrix: its button only asks, the restart is sent after you confirm in a dialog, and the window then says "Restarting <name>..." until the matrix has gone away and come back. Health also shows the matrix's cloud link (connected, last contact, installer ID). Health and Diagnostics come from the matrix's health report and show a tick or warning beside what the matrix judges; the System page says why the details couldn't be loaded when they couldn't.
* A connection attempt gets five seconds (`MainWindow.ConnectionGrace`) before the window says the matrix can't be reached, so a first attempt that fails while the network comes up doesn't look like an error.
* The admin password is kept in a plain file under `%APPDATA%\PulseEightControl` until the core gains
  Windows Credential Manager support.

## Updates in the app

`App/Updates/UpdateController.cs` checks about 30 seconds after start and then daily (when Settings > Updates > "Check for updates automatically" is on); `UpdateDialog.cs` shows the offer, downloads inside the dialog and hands over to the installer. Both are compiled only against the UI-free `PulseEight.Updates`.

A normal build has no feed or key, so it never checks (Settings says so). Release builds pass `-p:P8Version=<VERSION>.<build> -p:P8UpdateBaseUrl=<feed base URL> -p:P8UpdatePublicKey=<base64 Ed25519 public key>`; the version is what the feed's `sparkle:version` is compared against.

These WinUI files have not been compiled on a Mac; the first Windows build (CI or `build.ps1`) is their first check.

