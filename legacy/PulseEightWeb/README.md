# PulseEight Control

A management web app for a Pulse-Eight NeoMatrix HDBaseT matrix switcher: a
Dante Controller–style crosspoint grid (inputs on the X axis, outputs on the
Y axis), full hardware/system info, and per-port firmware update flags.

It's a single FastAPI process: a background task polls the matrix over its
local REST API (via the [`pulse-eight-matrix-client`](https://pypi.org/project/pulse-eight-matrix-client/)
library) and pushes live state to the browser over a WebSocket. The frontend
is plain HTML/CSS/JS — no build step.

## Setup

Requires Python 3.12+.

```bash
python3 -m venv .venv
./.venv/bin/pip install -r backend/requirements.txt
cp backend/config.example.json backend/config.json
```

Edit `backend/config.json` with your matrix's IP address:

```json
{
  "host": "192.168.1.150",
  "port": 80,
  "timeout": 10,
  "poll_interval": 5,
  "detail_poll_interval": 20,
  "admin_password": null
}
```

- `host` — required. IP address or hostname of the NeoMatrix.
- `port` — HTTP port the matrix's web API listens on (default `80`).
- `timeout` — request timeout in seconds.
- `poll_interval` — how often routing state is polled/broadcast, in seconds.
- `detail_poll_interval` — how often per-port details (signal, HDCP, link
  quality, firmware) are polled, in seconds.
- `admin_password` — the matrix's admin password (set on the device itself,
  under its own Admin panel). Only needed to rename ports; leave `null` for
  read-only/routing use.

There is no in-app settings UI by design — connection settings live only in
this file. Edit it and restart the server to change them.

## Run

```bash
cd backend
../.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Open `http://localhost:8000`.

## Running as a Windows service

Uses [NSSM](https://nssm.cc) to install PulseEight Control as a real Windows
service: shows up in `services.msc`, starts before any user logs in,
restarts itself on crash, log file with rotation. Scripts are in
`scripts/windows/`.

Do the regular Setup steps above first (venv + `pip install` + `config.json`)
— Windows or not, the app still needs those. Then, from an **elevated**
PowerShell prompt in the repo root:

```powershell
.\scripts\windows\install-service.ps1 -InstallNssm
```

`-InstallNssm` downloads and unpacks [NSSM](https://nssm.cc) into
`scripts\windows\tools` if it isn't already on `PATH` or at `-NssmPath`. If
you'd rather install it yourself (`choco install nssm -y`, or download the
zip from nssm.cc), just omit that flag — the script will tell you which
option it's expecting if it can't find NSSM.

A service has no interactive session, so the usual first-run "allow this app
through the firewall" prompt never appears — if other devices on your network
need to reach it, add `-AddFirewallRule` to open the port (`8000` by
default) in Windows Defender Firewall:

```powershell
.\scripts\windows\install-service.ps1 -AddFirewallRule
```

Remove the service with `.\scripts\windows\uninstall-service.ps1`, adding
`-RemoveFirewallRule` if you also want the firewall rule cleaned up. Both
scripts accept `-Port` and `-ServiceName` if you're not using the defaults
(match them between install and uninstall).

## Features

- **Routing** tab: crosspoint grid, click a cell to route an input to an
  output. Status dots on each header reflect signal/fault state. Hovering a
  cell or header highlights its row/column, same as Dante Controller. Click
  a header to open a detail drawer (signal, HDCP, link quality, cable
  length, connected sink, firmware version).
  - Rename a port (13 characters max, matching the device's own limit).
  - For inputs, set the EDID profile from a dropdown of real profile names
    (e.g. "Ultra HD (4k)", "Clone Display 3 — Lounge TV") rather than the
    raw numeric ID the device itself reports.
  - Both require `admin_password` in `config.json`. Neither is exposed by
    `pulse-eight-matrix-client` — found by inspecting the matrix's own admin
    web UI (`POST /Port/SetName/{Mode}/{Bay}/`, `GET /Port/EDID/Set/{profile}/{Bay}`).
- **Hardware** tab: system details (model, firmware, serial, MAC), feature
  capabilities (HDBaseT, CEC, PoE, etc.), a firmware-updates summary, a full
  ports table, and a front-panel logo backlight control (off/dim/bright —
  also admin-only, `POST /System/BacklightLED/{level}`).
- Firmware update availability comes from the matrix's own
  `firmware_version_available` flag per HDBaseT output/receiver — the app
  doesn't check any external update source.
- Live updates over WebSocket; the UI reconnects automatically if the
  connection drops, and the grid updates in place (no full redraw) so clicks
  never race a routing poll.
- If the matrix isn't configured or isn't reachable, a blocking dialog
  replaces the UI instead of showing stale routing/hardware data — it
  explains why (missing config vs. unreachable device) and, when applicable,
  offers a "Retry Now" button that forces an immediate reconnect attempt
  rather than waiting for the next background poll.
- Installable as a PWA (manifest + service worker caching the app shell only
  — live data always hits the network, never the cache). Browsers only offer
  the install prompt over HTTPS or on `localhost`; installing from a plain
  `http://<lan-ip>` won't be offered by most browsers.
- Light/Dark/System theme toggle in the top bar, persisted per-browser.
