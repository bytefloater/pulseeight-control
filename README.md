# PulseEight Control

Native desktop apps for managing a Pulse-Eight NeoMatrix HDBaseT matrix switcher: a crosspoint
routing grid (inputs across, outputs down), full hardware/system information and per-port
details, for macOS and Windows, sharing one Swift core.

## Layout

| Folder | What it is |
|---|---|
| `PulseEightKit/` | Swift package with everything that is not UI: the device client (`PulseEightKit`), settings, connection and commands (`PulseEightCore`), the C interface the Windows app loads (`PulseEightCoreExports` -> `pulseeight_core.dll`) and the `p8ctl` command-line tool. |
| `PulseEightFakeServer/` | Swift package with a fake NeoMatrix (`p8fake`) for development and tests, so no hardware or Python is needed. |
| `PulseEightControl-macos/` | The macOS app (SwiftCrossUI) over `PulseEightKit`. |
| `PulseEightControl-windows/` | The Windows app: WinUI 3 + C# (`App`) over a managed wrapper (`Core`) of the C interface, with its tests (`Core.Tests`). |
| `docs/` | Design notes, e.g. the C interface (`core-interface.md`). |
| `legacy/` | Retired code kept for reference: the original Python web app (`PulseEightWeb/`) and the SwiftCrossUI spike (`spikes/`). |

Open `PulseEightControl.xcworkspace` in Xcode to browse the packages together (macOS).

## Getting started

* **Windows:** see [`PulseEightControl-windows/README.md`](PulseEightControl-windows/README.md).
* **Shared code:** `swift test --package-path PulseEightKit`.
* **No matrix handy?** Run the fake server (see `PulseEightFakeServer/`) and point the app at `127.0.0.1`.

## Licence

See `LICENSE`.
