"""Calls NeoMatrix endpoints that pulse_eight_matrix_client doesn't expose
(it only covers routing/status). Found by inspecting the matrix's own admin
web UI (/admin/*.htm + /js/p8setup.min.js, p8fp.min.js):

- Renaming a port:      POST /Port/SetName/{Mode}/{Bay}/   body {"Name": ...}
- Setting EDID profile: GET  /Port/EDID/Set/{profile}/{Bay}
- Front panel backlight: POST /System/BacklightLED/{off|low|high}
- Front panel status LEDs: POST /System/StatusLED/{On|Off}

All gated behind POST /Account/Login. The device issues no session cookie on
login, so there's nothing to persist between calls — the same login+action
round trip is repeated each time.

The EDID profile IDs and names below aren't returned by the device anywhere;
they're a fixed table baked into the vendor's own admin JS (p8setup.min.js),
reproduced here verbatim. "Clone Display N" entries (IDs 101+bay) mirror an
actual connected output and are generated from the matrix's real output
ports rather than hardcoded.
"""

from dataclasses import dataclass

import aiohttp

MAX_NAME_LENGTH = 13  # matches maxlength on the device's own rename field
BACKLIGHT_LEVELS = ("off", "low", "high")

_STATIC_EDID_PROFILES: list[tuple[int, str]] = [
    (11, "Dynamic (Lowest Common Denominator)"),
    (4, "720p/2.0"),
    (0, "1080p/2.0 (Default)"),
    (3, "1080p/Dolby 5.1"),
    (5, "1080p/7.1"),
    (2, "Ultra HD (4k)"),
    (6, "Ultra HD (4k)/7.1"),
]
_HDR_EDID_PROFILES: list[tuple[int, str]] = [
    (7, "HDR10/Dolby 5.1"),
    (8, "HDR10/7.1"),
]
_CLONE_PROFILE_BASE = 101


@dataclass
class EdidProfile:
    id: int
    name: str


def build_edid_profiles(scrambling: bool, output_ports: list) -> list[EdidProfile]:
    """output_ports: Port objects (mode == "Output") from the live ports list."""
    profiles = [EdidProfile(tpl, name) for tpl, name in _STATIC_EDID_PROFILES]
    if scrambling:
        profiles += [EdidProfile(tpl, name) for tpl, name in _HDR_EDID_PROFILES]
    for output in sorted(output_ports, key=lambda p: p.bay):
        profiles.append(EdidProfile(_CLONE_PROFILE_BASE + output.bay, f"Clone Display {output.bay + 1} — {output.name}"))
    return profiles


class Pulse8AdminError(Exception):
    pass


class Pulse8AdminClient:
    def __init__(self, host: str, port: int = 80, timeout: int = 10):
        self._base_url = f"http://{host}:{port}"
        self._timeout = aiohttp.ClientTimeout(total=timeout)

    async def rename_port(self, mode: str, bay: int, name: str, admin_password: str) -> None:
        if len(name) > MAX_NAME_LENGTH:
            raise Pulse8AdminError(f"Name must be {MAX_NAME_LENGTH} characters or fewer")

        async with aiohttp.ClientSession(timeout=self._timeout) as session:
            await self._post(session, "/Account/Login", {"Password": admin_password})
            await self._post(session, f"/Port/SetName/{mode}/{bay}/", {"Name": name})

    async def set_edid_profile(self, bay: int, profile: int, admin_password: str) -> None:
        async with aiohttp.ClientSession(timeout=self._timeout) as session:
            await self._post(session, "/Account/Login", {"Password": admin_password})
            await self._get(session, f"/Port/EDID/Set/{profile}/{bay}")

    async def set_backlight(self, level: str, admin_password: str) -> None:
        if level not in BACKLIGHT_LEVELS:
            raise Pulse8AdminError(f"level must be one of: {', '.join(BACKLIGHT_LEVELS)}")

        async with aiohttp.ClientSession(timeout=self._timeout) as session:
            await self._post(session, "/Account/Login", {"Password": admin_password})
            await self._post(session, f"/System/BacklightLED/{level}", {})

    async def set_status_led(self, on: bool, admin_password: str) -> None:
        async with aiohttp.ClientSession(timeout=self._timeout) as session:
            await self._post(session, "/Account/Login", {"Password": admin_password})
            await self._post(session, f"/System/StatusLED/{'On' if on else 'Off'}", {})

    async def get_raw_system_features(self) -> dict:
        """A handful of pulse_eight_matrix_client's SystemFeatures fields are always None/False:
        their auto-generated alias only capitalizes the first letter (e.g. "BacklightLed", "Cec",
        "StatusLed") but the device sends all-caps acronyms ("BacklightLED", "CEC", "StatusLED").
        Fetched directly here to patch the affected fields after going through that (otherwise
        very convenient) model."""
        async with aiohttp.ClientSession(timeout=self._timeout) as session:
            return await self._get(session, "/system/features")

    async def _post(self, session: aiohttp.ClientSession, path: str, body: dict) -> dict:
        try:
            async with session.post(f"{self._base_url}{path}", json=body) as resp:
                return await self._parse(path, resp)
        except aiohttp.ClientError as exc:
            raise Pulse8AdminError(f"Failed to reach matrix: {exc}") from exc

    async def _get(self, session: aiohttp.ClientSession, path: str) -> dict:
        try:
            async with session.get(f"{self._base_url}{path}") as resp:
                return await self._parse(path, resp)
        except aiohttp.ClientError as exc:
            raise Pulse8AdminError(f"Failed to reach matrix: {exc}") from exc

    async def _parse(self, path: str, resp: aiohttp.ClientResponse) -> dict:
        if resp.status != 200:
            raise Pulse8AdminError(f"{path} returned HTTP {resp.status}")
        data = await resp.json(content_type=None)
        if not data.get("Result", False):
            raise Pulse8AdminError(data.get("Message") or f"{path} failed")
        return data
