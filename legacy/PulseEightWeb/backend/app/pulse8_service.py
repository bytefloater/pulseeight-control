"""Owns the connection to the Pulse8 NeoMatrix and keeps cached state fresh.

CachingPulseEightMatrixClient already background-polls /Port/List for routing
state. It doesn't poll system info or per-port details (signal, HDCP, link
quality, firmware update flags), so this service runs two extra loops on top
of it and broadcasts everything to connected WebSocket clients.
"""

import asyncio
import logging
import time
from typing import Any

from pulse_eight_matrix_client import (
    CachingPulseEightMatrixClient,
    InputPortDetails,
    OutputPortDetails,
    PulseEightAPIError,
    PulseEightConnectionError,
    PulseEightError,
    SetPortResponse,
    SystemDetails,
    SystemFeatures,
)

from .config import MatrixConfig, load_config
from .pulse8_admin import EdidProfile, Pulse8AdminClient, Pulse8AdminError, build_edid_profiles

_LOGGER = logging.getLogger(__name__)

# The library's own CachingPulseEightMatrixClient logs a full traceback
# (exc_info=True) every time its background poll fails to reach the matrix.
# We handle connection failures ourselves with a clean one-line message
# below, so that noise is silenced here rather than at the root logger.
logging.getLogger("pulse_eight_matrix_client").setLevel(logging.ERROR)

# System info and per-port details change far less often than routing state,
# so they're polled on their own slower cadence.
SYSTEM_POLL_INTERVAL = 60


class ConnectionManager:
    """Tracks connected WebSocket clients and fans out broadcasts."""

    def __init__(self) -> None:
        self._clients: set[Any] = set()

    async def connect(self, websocket: Any) -> None:
        await websocket.accept()
        self._clients.add(websocket)

    def disconnect(self, websocket: Any) -> None:
        self._clients.discard(websocket)

    async def broadcast(self, message: dict) -> None:
        dead = []
        for ws in self._clients:
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self._clients.discard(ws)


class Pulse8Service:
    def __init__(self, connections: ConnectionManager) -> None:
        self._connections = connections
        self.config: MatrixConfig = load_config()
        self.client: CachingPulseEightMatrixClient | None = None
        self.admin_client: Pulse8AdminClient | None = None

        self.system_details: SystemDetails | None = None
        self.system_features: SystemFeatures | None = None
        self.input_details: dict[int, InputPortDetails] = {}
        self.output_details: dict[int, OutputPortDetails] = {}

        self.last_error: str | None = None
        self._connected_once = False
        self._was_connected: bool | None = None

        self._connect_task: asyncio.Task | None = None
        self._routing_task: asyncio.Task | None = None
        self._details_task: asyncio.Task | None = None

    # -- lifecycle ---------------------------------------------------

    async def start(self) -> None:
        if not self.config.host:
            return
        self.client = CachingPulseEightMatrixClient(
            host=self.config.host,
            port=self.config.port,
            timeout=self.config.timeout,
            poll_interval=self.config.poll_interval,
        )
        self.admin_client = Pulse8AdminClient(
            host=self.config.host, port=self.config.port, timeout=self.config.timeout
        )
        # client.connect() blocks until its first poll succeeds or times out
        # (up to `timeout` seconds if the matrix is unreachable). Run it in
        # the background so app startup - and the web UI - isn't held hostage
        # by a misconfigured or temporarily offline device.
        self._connect_task = asyncio.create_task(self._connect_and_run())

    async def _connect_and_run(self) -> None:
        assert self.client is not None
        await self.client.connect()
        self._routing_task = asyncio.create_task(self._routing_broadcast_loop())
        self._details_task = asyncio.create_task(self._details_poll_loop())

    async def stop(self) -> None:
        for task in (self._connect_task, self._routing_task, self._details_task):
            if task:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass
        self._connect_task = None
        self._routing_task = None
        self._details_task = None
        if self.client:
            await self.client.close()
            self.client = None
        self.admin_client = None
        self.system_details = None
        self.system_features = None
        self.input_details = {}
        self.output_details = {}
        self._connected_once = False

    # -- status --------------------------------------------------------

    @property
    def connected(self) -> bool:
        if not self.client:
            return False
        age = self.client.get_cache_age()
        if age is None:
            return False
        return age < max(self.config.poll_interval * 3, 15)

    def status(self) -> dict:
        age = self.client.get_cache_age() if self.client else None
        last_poll = self.client.get_last_poll_time() if self.client else None
        return {
            "configured": self.config.host is not None,
            "connected": self.connected,
            "host": self.config.host,
            "port": self.config.port,
            "error": self.last_error,
            "last_poll_time": last_poll,
            "cache_age": age,
        }

    async def reconnect(self) -> None:
        """Force an immediate retry instead of waiting for the next poll tick."""
        if not self.client:
            raise RuntimeError("Matrix is not configured")
        await self.client.force_cache_update()
        await self._broadcast_ports()

    def _note_connection_result(self, ok: bool, exc: Exception | None = None) -> None:
        """Log connection loss/recovery once, on the transition, instead of every poll."""
        was_connected = self._was_connected
        self._was_connected = ok
        if ok and was_connected is False:
            _LOGGER.info("Reconnected to matrix at %s:%s", self.config.host, self.config.port)
        elif not ok and was_connected is not False:
            _LOGGER.warning("Lost connection to matrix at %s:%s: %s", self.config.host, self.config.port, exc)

    # -- routing ---------------------------------------------------------

    async def get_ports(self):
        if not self.client:
            return []
        return self.client.get_cached_ports()

    async def set_port(self, input_bay: int, output_bay: int) -> SetPortResponse:
        if not self.client:
            raise RuntimeError("Matrix is not configured")
        result = await self.client.set_port(input_bay, output_bay)
        await self._broadcast_ports()
        asyncio.create_task(self._refresh_details())
        return result

    async def route_by_name(self, input_name: str, output_name: str) -> SetPortResponse:
        if not self.client:
            raise RuntimeError("Matrix is not configured")
        result = await self.client.route_by_name(input_name, output_name)
        await self._broadcast_ports()
        asyncio.create_task(self._refresh_details())
        return result

    async def rename_port(self, mode: str, bay: int, name: str) -> None:
        if not self.client or not self.admin_client:
            raise RuntimeError("Matrix is not configured")
        if not self.config.admin_password:
            raise Pulse8AdminError("admin_password is not set in config.json")
        await self.admin_client.rename_port(mode, bay, name, self.config.admin_password)
        await self.client.force_cache_update()
        await self._broadcast_ports()
        asyncio.create_task(self._refresh_details())

    def edid_profiles(self) -> list[EdidProfile]:
        scrambling = bool(
            self.system_features and self.system_features.video and self.system_features.video.scrambling
        )
        outputs = [p for p in self.client.get_cached_ports() if p.mode == "Output"] if self.client else []
        return build_edid_profiles(scrambling, outputs)

    async def set_edid_profile(self, bay: int, profile: int) -> None:
        if not self.client or not self.admin_client:
            raise RuntimeError("Matrix is not configured")
        if not self.config.admin_password:
            raise Pulse8AdminError("admin_password is not set in config.json")
        await self.admin_client.set_edid_profile(bay, profile, self.config.admin_password)
        asyncio.create_task(self._refresh_details())

    async def set_backlight(self, level: str) -> None:
        if not self.admin_client:
            raise RuntimeError("Matrix is not configured")
        if not self.config.admin_password:
            raise Pulse8AdminError("admin_password is not set in config.json")
        await self.admin_client.set_backlight(level, self.config.admin_password)
        asyncio.create_task(self._refresh_system_info())

    async def set_status_led(self, on: bool) -> None:
        if not self.admin_client:
            raise RuntimeError("Matrix is not configured")
        if not self.config.admin_password:
            raise Pulse8AdminError("admin_password is not set in config.json")
        await self.admin_client.set_status_led(on, self.config.admin_password)
        asyncio.create_task(self._refresh_system_info())

    def updates_available(self) -> list[dict]:
        updates = []
        for bay, details in sorted(self.output_details.items()):
            if details.firmware_version_available:
                updates.append(
                    {
                        "bay": bay,
                        "name": details.name,
                        "firmware_version": details.firmware_version,
                        "firmware_version_available": True,
                    }
                )
        return updates

    # -- background loops --------------------------------------------------

    async def _routing_broadcast_loop(self) -> None:
        assert self.client is not None
        try:
            while True:
                await asyncio.sleep(self.config.poll_interval)
                await self._broadcast_ports()
        except asyncio.CancelledError:
            pass

    async def _broadcast_ports(self) -> None:
        ports = await self.get_ports()
        await self._connections.broadcast(
            {
                "type": "ports",
                "data": [p.model_dump(mode="json") for p in ports],
            }
        )
        await self._connections.broadcast({"type": "status", "data": self.status()})

    async def _details_poll_loop(self) -> None:
        assert self.client is not None
        system_last_fetch = 0.0
        try:
            while True:
                if time.monotonic() - system_last_fetch >= SYSTEM_POLL_INTERVAL:
                    await self._refresh_system_info()
                    system_last_fetch = time.monotonic()
                await self._refresh_details()
                await asyncio.sleep(self.config.detail_poll_interval)
        except asyncio.CancelledError:
            pass

    async def _apply_raw_feature_corrections(self) -> None:
        """Patch the fields pulse_eight_matrix_client silently gets wrong (see
        Pulse8AdminClient.get_raw_system_features). No-op if system_features hasn't
        been fetched yet or the admin client isn't available."""
        if not self.admin_client or not self.system_features:
            return
        try:
            raw = await self.admin_client.get_raw_system_features()
        except Pulse8AdminError:
            return  # not critical; those fields just won't show correctly
        if raw.get("BacklightLED"):
            self.system_features.backlight_led = raw["BacklightLED"].lower()
        if raw.get("StatusLED"):
            self.system_features.status_led = raw["StatusLED"].lower()
        if "CEC" in raw:
            self.system_features.cec = bool(raw["CEC"])

    async def _broadcast_system(self) -> None:
        if not self.system_details or not self.system_features:
            return
        await self._connections.broadcast(
            {
                "type": "system",
                "data": {
                    "details": self.system_details.model_dump(mode="json"),
                    "features": self.system_features.model_dump(mode="json"),
                },
            }
        )

    async def _refresh_system_info(self) -> None:
        assert self.client is not None
        try:
            self.system_details = await self.client.get_system_details()
            self.system_features = await self.client.get_system_features()
            await self._apply_raw_feature_corrections()
            self.last_error = None
            self._connected_once = True
            await self._broadcast_system()
        except PulseEightConnectionError as exc:
            self.last_error = str(exc)
            _LOGGER.warning("Could not reach matrix for system info: %s", exc)
            await self._connections.broadcast({"type": "status", "data": self.status()})
        except PulseEightAPIError as exc:
            self.last_error = str(exc)
            _LOGGER.warning("Matrix API error fetching system info: %s", exc)
            await self._connections.broadcast({"type": "status", "data": self.status()})

    async def _refresh_details(self) -> None:
        assert self.client is not None
        try:
            ports = await self.client.get_ports()
        except PulseEightConnectionError as exc:
            self.last_error = str(exc)
            self._note_connection_result(False, exc)
            await self._connections.broadcast({"type": "status", "data": self.status()})
            return
        except PulseEightAPIError as exc:
            self.last_error = str(exc)
            _LOGGER.warning("Matrix API error fetching ports: %s", exc)
            await self._connections.broadcast({"type": "status", "data": self.status()})
            return

        self.last_error = None
        self._connected_once = True
        self._note_connection_result(True)

        for port in ports:
            try:
                if port.mode == "Input":
                    self.input_details[port.bay] = await self.client.get_input_details(port.bay)
                elif port.mode == "Output":
                    self.output_details[port.bay] = await self.client.get_output_details(port.bay)
            except PulseEightError as exc:
                _LOGGER.warning("Failed to fetch details for %s bay %s: %s", port.mode, port.bay, exc)

        await self._connections.broadcast(
            {
                "type": "details",
                "data": {
                    "inputs": {b: d.model_dump(mode="json") for b, d in self.input_details.items()},
                    "outputs": {b: d.model_dump(mode="json") for b, d in self.output_details.items()},
                },
            }
        )
        await self._connections.broadcast(
            {"type": "updates", "data": self.updates_available()}
        )
        # Front panel backlight is user-changeable at any time (physical button,
        # matrix's own admin UI, ...), so it rides the same fast cadence as
        # routing/port details rather than the slower full system-info refresh.
        await self._apply_raw_feature_corrections()
        await self._broadcast_system()
        await self._connections.broadcast({"type": "status", "data": self.status()})
