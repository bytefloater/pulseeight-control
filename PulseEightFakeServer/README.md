# PulseEightFakeServer

A stand-in for a Pulse-Eight NeoMatrix, so the apps, `p8ctl` and the tests can run without hardware.
Swift, Foundation only (plain sockets: WinSock2 on Windows, BSD sockets elsewhere; no libdispatch,
`URLSession` or third-party packages).

| Target | What it is |
|---|---|
| `PulseEightFakeMatrix` | The library. `FakeMatrix` holds the state and answers requests; `FakeMatrixServer` serves it over HTTP; `FakeMatrixTransport` plugs it into PulseEightKit in-process (no sockets) for tests. |
| `p8fake` | The command-line server. |

## Run it

```
swift run --package-path PulseEightFakeServer p8fake --port 8080 --password secret
```

| Option | Meaning |
|---|---|
| `--host HOST` | Address to listen on (default `127.0.0.1`; `0.0.0.0` for the whole network). |
| `--port PORT` | Port (default `8080`). |
| `--password TEXT` | Admin password. Omit to let admin calls through without a login. |
| `--bays N` | Inputs and outputs per side (default 8; real hardware has 8 or 16). |
| `--latency SECONDS` | Delay every reply, to see pending states in a UI. |
| `--quiet` | Don't log each request. |

Then point an app at it (Settings: `127.0.0.1`, port `8080`) or use the CLI:

```
swift run --package-path PulseEightKit p8ctl --host 127.0.0.1 --port 8080 ports
```

## What it serves

```
GET  /System/Details, /system/features
GET  /Port/List
GET  /Port/Details/{Input|Output}/{bay}
GET  /Port/Set/{input}/{output}
GET  /Port/EDID/Set/{profile}/{bay}                (admin)
POST /Account/Login                                {"Password": ...}
POST /Port/SetName/{Input|Output}/{bay}/           {"Name": ...} (admin, 13 characters at most)
POST /System/BacklightLED/{off|low|high}           (admin)
POST /System/StatusLED/{On|Off}                    (admin)
```

Payload shapes are synthetic (built from the field names the client reads), not real device
captures. Sample data: inputs "Sky", "Apple TV", "Input 3"... (every third has no signal); outputs
"Lounge TV", "Bedroom TV", "Output 3"... (output 3 has a firmware update waiting).

## Tests

```
swift test --package-path PulseEightFakeServer
```

Covers the real PulseEightKit clients against the fake in-process, the routing rules, and the
socket server (including concurrent requests) with the transport the apps use on this platform.
The Windows app's `Core.Tests` start `p8fake` themselves (set `P8_FAKE_SERVER` to its path, or build it
in this folder with `swift build`).
