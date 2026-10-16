# PulseEight Control for Windows

A native WinUI 3 app. The interface is written in C#; everything that talks to the matrix
(connection, polling, settings, the admin password, validation and every command) is the shared
Swift core in `../PulseEightKit`, loaded as `pulseeight_core.dll` and driven with JSON. See
`../docs/core-interface.md`.

| Project | What it is |
|---|---|
| `Core` (`PulseEight.Core`) | Managed wrapper over the C interface (`CoreClient`, snapshot types). No UI, builds on any OS. |
| `Core.Tests` | xUnit tests; the end-to-end ones run against the real library and `tools/fake_matrix.py`. |
| `App` (`PulseEightControl`) | The WinUI 3 app. The interface is built in code; the only XAML is `App.xaml`, which WinUI needs to load its control styles. |

## Build and run (on Windows)

Needs the Swift toolchain, the .NET 8 (or newer) SDK and Python 3 (only for the tests).

```powershell
.\windows\build.ps1 -Run
```

That builds `pulseeight_core.dll`, stages it with the Swift runtime DLLs in `windows\native\<arch>`,
builds the app (self-contained: no Windows App Runtime install needed) and starts it. Crashes are
written to `%LOCALAPPDATA%\PulseEightControl\crash.log`.

To try it without a matrix, run `python tools\fake_matrix.py --port 8080 --password secret` and use
`127.0.0.1`, port `8080` in Settings.

## Tests

```powershell
swift build --package-path PulseEightKit --product pulseeight_core
$env:P8_CORE_LIBRARY = "$PWD\swift\.build\debug\pulseeight_core.dll"
dotnet test windows\PulseEight.Core.Tests
```

Without `P8_CORE_LIBRARY` the end-to-end tests are skipped. On macOS use
`libpulseeight_core.dylib` (and `DOTNET_ROLL_FORWARD=Major` if only a newer .NET runtime is installed).

## Notes

* The app can be type-checked off Windows with
  `dotnet build PulseEightControl-windows/App -p:EnableWindowsTargeting=true -p:Platform=ARM64 -p:WindowsAppSDKSelfContained=false -p:SelfContained=false -p:ApplicationManifest=`
  (the manifest and XAML tools only run on Windows, so off Windows this can no longer compile `App.xaml`; build on Windows to type-check). That catches compile errors, not runtime ones.
* The admin password is kept in a plain file under `%APPDATA%\PulseEightControl` until the core gains
  Windows Credential Manager support.
