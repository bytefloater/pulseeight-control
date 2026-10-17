# PulseEight Control for Windows

A native WinUI 3 app. The interface is written in C#; everything that talks to the matrix
(connection, polling, settings, the admin password, validation, every command and all user-visible
text) is the shared Swift core in `../PulseEightKit`, loaded as `pulseeight_core.dll` and driven with
JSON. See `../docs/core-interface.md` and `../docs/localisation.md`.

| Project | What it is |
|---|---|
| `Core` (`PulseEight.Core`) | Managed wrapper over the C interface (`CoreClient`, snapshot types). No UI, builds on any OS. |
| `Core.Tests` | xUnit tests; the end-to-end ones run against the real library and the Swift fake matrix (`../PulseEightFakeServer`). |
| `App` (`PulseEightControl`) | The WinUI 3 app. The interface is built in code; the only XAML is `App.xaml`, which WinUI needs to load its control styles. |

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
* The admin password is kept in a plain file under `%APPDATA%\PulseEightControl` until the core gains
  Windows Credential Manager support.
