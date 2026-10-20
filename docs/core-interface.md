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

Request `{"cmd": "...", ...}`; response `{"ok":true}` (plus `"value"` for `validatePortName`, `strings`, `discover` and `saveMatrix`) or
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
| `saveMatrix` | Adds a matrix, or changes the one named by `id`. Fields: optional `id`, `name` (blank shows the address), `host`, `port`, `timeout`, `pollInterval`, `detailPollInterval` (strings or numbers), optional `adminPassword` (empty keeps the saved one), optional `clearAdminPassword`: bool. Returns the matrix's id in `value`. The first matrix added becomes the selected one; later ones don't. Reconnects if the selected matrix's connection changed. |
| `selectMatrix` | `id`: the matrix to show. Stops talking to the current one and connects to this one. |
| `removeMatrix` | `id`. Also forgets its admin password. If it was selected, the first remaining matrix is. |
| `saveSettings` | The single-matrix form, kept for older callers: saves the **selected** matrix (adding one if there is none), keeping its name. Same fields as `saveMatrix` minus `id`, `name` and `clearAdminPassword`. |
| `restart` | Restarts the selected matrix (admin only; fails without a saved admin password). The matrix does it **the moment it is asked, with no confirmation of its own**, and everything routed through it is interrupted for about a minute, so the command refuses unless the request has `"confirmed": true`: ask the person first, and only then send it. It is sent once and never retried. Afterwards the matrix is unreachable until it has started again; polling carries on and the connection returns by itself. |
| `removeAdminPassword` | Forgets the selected matrix's admin password. |
| `setAppearance` | `value`: `system`, `light`, `dark` |
| `setLanguage` | `value`: a code from the snapshot's `languages`, or `system` |
| `strings` | returns the whole text table for the language in force, a JSON object in `value` (see [localisation](localisation.md)) |
| `setHighlightGrid`, `setShowStatusBar` | `on`: bool |
| `setUpdatePrereleases` | `on`: true (offer release candidates and betas too), false (releases only) or null (follow the installed build: a pre-release build keeps getting pre-releases). Both updaters read it from `settings.updatePrereleases`; the app turns it into the feed channels (`rc` and `beta`). |
| `setCheckForUpdates` | `on`: bool. Whether the app looks for updates by itself. Read by the Windows updater; the macOS app leaves this to Sparkle. |
| `validatePortName` | `name`; returns the trimmed name in `value` |
| `discover` | no fields. Asks gotomymatrix.com which matrix is on this network (needs internet). Returns `{"host":"192.168.1.50","port":80}` as text in `value`, or no `value` if it knows of none. Changes no setting: show the answer, then send `saveSettings` if the user accepts it. Only private-network addresses are accepted. |

Admin-gated commands (`renamePort`, `setEdid`, `setBacklight`, `setStatusLed`, `restart`) fail with a message
if no admin password is saved.

## Snapshot

`schema` is `1`. Bays are zero-based (`bay`), display numbers one-based (`number`).

```
schema, phase, phaseDetail?, summary, hostLabel (the selected matrix's name, or its address when it has none), adminConfigured (for the selected matrix),
language ("en": the language in force), languages [ {code, name} ] (name is in that language),
settings { appearance, highlightGrid, showStatusBar, checkForUpdates, updatePrereleases? (true/false; absent = follow the build), language ("system" or a code), host?, port, timeout,
           pollInterval, detailPollInterval }   (host onwards: the selected matrix),
matrices [ {id, name, displayName, host?, port, timeout, pollInterval, detailPollInterval, adminPasswordSaved, selected} ]
           (every configured matrix, in the order added; the admin password itself is never included),
inputs[], outputs[]  -> port {
    mode, bay, number, name, type,
    status (0 ok, 1 module fault, 2 warning, 3 no signal, 4 not present), statusLabel,
    receiveFrom?, sourceName?    (outputs: the routed input)
    updateAvailable, edidProfile? (inputs)
    details [ {label, value} ]    (empty until the matrix details load)
},
systemRows[], healthRows[], featureRows[]   -> [ {label, value} ]  (identical text on both platforms; healthRows is the matrix's
                                  own health report: status, uptime, power supplies and modules, temperatures, supply rails; empty
                                  until it loads and for firmware that has none; the `health` group ends with the cloud link: "Cloud connection" (`ok` true/false),
                                  "Last contact" (how long ago the matrix last reported in) and "Installer ID", when the matrix offers them). Each healthRow also has `group` (`health`: the
                                  matrix's verdict and its parts; `diagnostics`: temperatures and supply rails) and, where the
                                  matrix judges it, `ok` (true/false); neither is present on other rows)
systemError?                  -> why the system details couldn't be loaded (they are missing while this is set)
model?, firmware?,
frontPanel? { backlight? ("off"|"low"|"high"), statusLed? },
updates [ {bay, name, firmwareVersion?} ],
edidProfiles [ {id, name} ]
```

`phase` is `notConfigured`, `connecting`, `connected` or `disconnected` (`phaseDetail` says why).
`summary` is ready-made text such as `Connected to 192.168.1.150`. Every piece of text in the snapshot
(`summary`, `statusLabel`, the `label`/`value` rows, error messages) is already in the language in force.

## Building the library

macOS: `swift build --package-path PulseEightKit` produces `libpulseeight_core.dylib`.

Windows: `swift build --package-path PulseEightKit` produces `pulseeight_core.dll`. It needs the Swift
runtime DLLs (`swiftCore.dll`, `Foundation.dll`, ...) beside it at run time; the packaging step
copies them next to the app.

## Environment variables (development)

`P8_CONFIG_DIR` overrides the settings folder; `P8_SECRET_STORE=file` forces the file-based secret
store (the default on Windows until Credential Manager support lands).
