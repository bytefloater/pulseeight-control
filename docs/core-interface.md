# PulseEight core interface

The logic shared by the macOS and Windows apps lives in Swift (`PulseEightKit/Sources/PulseEightCore`):
settings and the admin password, the connection to the matrix and its polling, the connection
phase, validation, and every command. Each app draws its own native UI on top.

* **macOS** links `PulseEightCore` directly and uses the typed Swift API (`AppCore`).
* **Windows** loads `pulseeight_core.dll` (built from `PulseEightCoreExports`) and talks JSON
  through the C functions in `PulseEightKit/include/pulseeight_core.h`, via the C# wrapper in
  `PulseEightControl-windows/Core` (`CoreClient`).

`PulseEightControl-windows/Core.Tests` exercises the C interface end to end (P/Invoke against the real library and the Swift fake matrix, `PulseEightFakeServer`), and is
the executable reference for how a client uses it.

## Functions

| Function | Purpose |
|---|---|
| `p8_abi_version()` | Currently `1`. Check it at startup. |
| `p8_create()` | Load settings, start connecting in the background. Returns a handle. |
| `p8_destroy(h)` | Release the handle. |
| `p8_snapshot(h)` | Current state as JSON (below). |
| `p8_call(h, request)` | Run one command, return the JSON result. **Blocks**: call it from a worker thread. |
| `p8_set_observer(h, cb, ctx)` | `cb(ctx, snapshotJson)` after every change, on a background thread. Marshal to the UI thread. |
| `p8_free_string(s)` | Free any string the library returned. |

Quiet polls (only timestamps changed) do not fire the observer.

## Commands (`p8_call`)

Request `{"cmd": "...", ...}`; response `{"ok":true}` (plus `"value"` for `validatePortName`) or
`{"ok":false,"error":"message ready to show"}`.

| `cmd` | Fields |
|---|---|
| `route` | `input`, `output` (zero-based bays) |
| `renamePort` | `mode` (`"Input"`/`"Output"`), `bay`, `name` (validated: 1-13 characters) |
| `setEdid` | `bay` (input), `profile` (id from `edidProfiles`) |
| `setBacklight` | `level`: `off`, `low`, `high` |
| `setStatusLed` | `on`: bool |
| `retry` | poll now |
| `reconnect` | drop the connection and reconnect from saved settings |
| `saveSettings` | `host`, `port`, `timeout`, `pollInterval`, `detailPollInterval` (strings or numbers), optional `adminPassword` (empty keeps the saved one) |
| `removeAdminPassword` | |
| `setAppearance` | `value`: `system`, `light`, `dark` |
| `setHighlightGrid`, `setShowStatusBar` | `on`: bool |
| `validatePortName` | `name`; returns the trimmed name in `value` |

Admin-gated commands (`renamePort`, `setEdid`, `setBacklight`, `setStatusLed`) fail with a message
if no admin password is saved.

## Snapshot

`schema` is `1`. Bays are zero-based (`bay`), display numbers one-based (`number`).

```
schema, phase, phaseDetail?, summary, hostLabel, adminConfigured,
settings { appearance, highlightGrid, showStatusBar, host?, port, timeout, pollInterval, detailPollInterval },
inputs[], outputs[]  -> port {
    mode, bay, number, name, type,
    status (0 ok, 1 module fault, 2 warning, 3 no signal, 4 not present), statusLabel,
    receiveFrom?, sourceName?    (outputs: the routed input)
    updateAvailable, edidProfile? (inputs)
    details [ {label, value} ]    (empty until the matrix details load)
},
systemRows[], featureRows[]   -> [ {label, value} ]  (identical text on both platforms)
model?, firmware?,
frontPanel? { backlight? ("off"|"low"|"high"), statusLed? },
updates [ {bay, name, firmwareVersion?} ],
edidProfiles [ {id, name} ]
```

`phase` is `notConfigured`, `connecting`, `connected` or `disconnected` (`phaseDetail` says why).
`summary` is ready-made text such as `Connected to 192.168.1.150`.

## Building the library

macOS: `swift build --package-path swift` produces `libpulseeight_core.dylib`.

Windows: `swift build --package-path swift` produces `pulseeight_core.dll`. It needs the Swift
runtime DLLs (`swiftCore.dll`, `Foundation.dll`, ...) beside it at run time; the packaging step
copies them next to the app.

## Environment variables (development)

`P8_CONFIG_DIR` overrides the settings folder; `P8_SECRET_STORE=file` forces the file-based secret
store (the default on Windows until Credential Manager support lands).
