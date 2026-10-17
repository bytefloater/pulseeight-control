# PulseEight Control

Native desktop apps for managing a Pulse-Eight NeoMatrix HDBaseT matrix switcher: a crosspoint
routing grid (inputs across, outputs down), full hardware/system information and per-port
details, for macOS and Windows, sharing one Swift core.

## Layout

| Folder | What it is |
|---|---|
| `PulseEightKit/` | Swift package with everything that is not UI: the device client (`PulseEightKit`), settings, connection and commands (`PulseEightCore`), the C interface the Windows app loads (`PulseEightCoreExports` -> `pulseeight_core.dll`) and the `p8ctl` command-line tool. |
| `PulseEightFakeServer/` | Swift package with a fake NeoMatrix (`p8fake`) for development and tests, so no hardware or Python is needed. |
| `PulseEightControl-macos/` | The macOS app (SwiftUI) over `PulseEightKit`. |
| `PulseEightControl-windows/` | The Windows app: WinUI 3 + C# (`App`) over a managed wrapper (`Core`) of the C interface, with its tests (`Core.Tests`). |
| `docs/` | Design notes: the C interface (`core-interface.md`) and how text is localised (`localisation.md`). |
| `legacy/` | Retired code kept for reference: the original Python web app (`PulseEightWeb/`) and the SwiftCrossUI spike (`spikes/`). |

Open `PulseEightControl.xcworkspace` in Xcode to build, run and test everything on macOS (see below).

## Getting started

* **Windows:** see [`PulseEightControl-windows/README.md`](PulseEightControl-windows/README.md).
* **Shared code:** `swift test --package-path PulseEightKit` (and `PulseEightFakeServer`).
* **Build output** of the Windows build goes under `out/` (short paths, gitignored; delete it to build clean).
* **No matrix handy?** Run the fake server (see `PulseEightFakeServer/`) and point the app at `127.0.0.1`.

## Developing in VS Code

Open the repository folder; `.vscode/extensions.json` recommends the extensions (Swift, LLDB DAP, and
C# for debugging the Windows app). The same task names work on Windows and macOS (**Terminal > Run Task**,
or **Ctrl/Cmd+Shift+B** for the default build):

| Task | Windows | macOS |
|---|---|---|
| `Build: app (debug)` (default build) | core + WinUI app (`PulseEightControl-windows/build.ps1`) | `swift build` of the SwiftUI app |
| `Build: app (release)` | same, `-Configuration Release` | `swift build -c release` |
| `Package: macOS app` | (macOS only) | `PulseEightControl-macos/package.sh`: builds `out/macos/PulseEightControl.app` with its icon (`PulseEightControl.icon`) |
| `Run: app` | build and start the app | build and start the app |
| `Run: app against fake matrix` | starts `p8fake`, then runs the app with a throwaway config (`out/dev-config`) that points at it | same |
| `Test: all` | Swift tests for `PulseEightKit` and `PulseEightFakeServer`, plus the C# end-to-end tests | the two Swift suites |
| `Fake matrix: start` | runs `p8fake` on `127.0.0.1:8080` (admin password `secret`) | same |
| `Clean: all build output` | deletes `out/` and the Swift `.build` folders | same |

Debug configurations (**Run and Debug**): `Debug app (Windows ARM64 / x64)` and `Debug app (macOS)`, each
also in an "against fake matrix" variant, plus `Debug p8ctl` and `Debug p8fake`. The dev config uses the
file secret store (`P8_SECRET_STORE=file`), so nothing touches your real settings or the Keychain.

## Developing in Xcode (macOS)

Open `PulseEightControl.xcworkspace`. The macOS app is a real app target
(`PulseEightControl-macos/PulseEightControl.xcodeproj`) over the `PulseEightKit` and `PulseEightFakeServer`
packages, with the Icon Composer icon (`PulseEightControl.icon`) built in, so Run, Archive and the Dock all
show the icon. The shared schemes cover the same ground as the VS Code tasks:

| Scheme | What it does |
|---|---|
| `PulseEightControl` | Build and run the app (Release/Archive give the distributable `.app`). |
| `PulseEightControl (Fake Matrix)` | Starts `p8fake` in the background (`xcode/fake-matrix.sh`), then runs the app with the throwaway config in `out/dev-config` and the file secret store; stops the fake when the run ends. The admin password is `secret`. |
| `p8fake` | Runs the fake matrix on `127.0.0.1:8080` under the debugger. |
| `p8ctl (Fake Matrix)` | Runs `p8ctl ports` against the fake matrix (started and stopped for you). |
| `All Tests` | Tests for `PulseEightKit`, `PulseEightCore` and `PulseEightFakeServer` (**Cmd+U**). |
| `Clean All` | Build it to delete `out/` and the Swift `.build` folders (`xcode/clean.sh`). |

The Windows app is not part of the Xcode project. The `Package.swift` next to the project still builds the
same sources with `swift build` (used by VS Code); `package.sh` there builds the `.app` without Xcode.

## Licence

See `LICENSE`.
