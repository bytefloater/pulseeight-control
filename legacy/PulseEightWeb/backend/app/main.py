"""FastAPI app: REST + WebSocket control surface for a Pulse8 NeoMatrix."""

import logging
from contextlib import asynccontextmanager
from dataclasses import asdict
from pathlib import Path

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from pulse_eight_matrix_client import PulseEightError

from .pulse8_admin import Pulse8AdminError
from .pulse8_service import ConnectionManager, Pulse8Service
from .schemas import (
    PortUpdateInfo,
    RenamePortRequest,
    RouteByNameRequest,
    RouteRequest,
    SetBacklightRequest,
    SetEdidRequest,
    SetStatusLedRequest,
)

logging.basicConfig(level=logging.INFO)

connections = ConnectionManager()
service = Pulse8Service(connections)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await service.start()
    yield
    await service.stop()


app = FastAPI(title="PulseEight Control", lifespan=lifespan)


def _snapshot() -> list[dict]:
    """Everything a freshly-opened browser tab needs, sent right after connect."""
    messages = [{"type": "status", "data": service.status()}]
    if service.system_details and service.system_features:
        messages.append(
            {
                "type": "system",
                "data": {
                    "details": service.system_details.model_dump(mode="json"),
                    "features": service.system_features.model_dump(mode="json"),
                },
            }
        )
    if service.input_details or service.output_details:
        messages.append(
            {
                "type": "details",
                "data": {
                    "inputs": {b: d.model_dump(mode="json") for b, d in service.input_details.items()},
                    "outputs": {b: d.model_dump(mode="json") for b, d in service.output_details.items()},
                },
            }
        )
        messages.append({"type": "updates", "data": service.updates_available()})
    return messages


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    await connections.connect(websocket)
    try:
        ports = await service.get_ports()
        await websocket.send_json({"type": "ports", "data": [p.model_dump(mode="json") for p in ports]})
        for message in _snapshot():
            await websocket.send_json(message)
        while True:
            # Client doesn't need to send anything; just keep the socket open.
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        connections.disconnect(websocket)


@app.get("/api/status")
async def get_status() -> dict:
    return service.status()


@app.post("/api/reconnect")
async def reconnect() -> dict:
    """Force an immediate retry rather than waiting for the next background poll."""
    try:
        await service.reconnect()
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return service.status()


@app.get("/api/config")
async def get_config() -> dict:
    """Read-only: the config actually in effect. Edit config.json and restart to change it."""
    return {
        **service.config.model_dump(exclude={"admin_password"}),
        "admin_configured": bool(service.config.admin_password),
    }


@app.get("/api/system")
async def get_system() -> dict:
    if not service.system_details or not service.system_features:
        raise HTTPException(status_code=503, detail="System information not yet available")
    return {
        "details": service.system_details.model_dump(mode="json"),
        "features": service.system_features.model_dump(mode="json"),
    }


@app.get("/api/ports")
async def list_ports() -> list[dict]:
    ports = await service.get_ports()
    return [p.model_dump(mode="json") for p in ports]


@app.get("/api/ports/input/{bay}")
async def get_input_port(bay: int) -> dict:
    if bay not in service.input_details:
        raise HTTPException(status_code=404, detail="No details cached yet for this input")
    return service.input_details[bay].model_dump(mode="json")


@app.get("/api/ports/output/{bay}")
async def get_output_port(bay: int) -> dict:
    if bay not in service.output_details:
        raise HTTPException(status_code=404, detail="No details cached yet for this output")
    return service.output_details[bay].model_dump(mode="json")


@app.get("/api/updates", response_model=list[PortUpdateInfo])
async def list_updates() -> list[dict]:
    return service.updates_available()


@app.post("/api/route")
async def route(req: RouteRequest) -> dict:
    try:
        result = await service.set_port(req.input_bay, req.output_bay)
    except PulseEightError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return result.model_dump(mode="json")


@app.post("/api/ports/rename")
async def rename_port(req: RenamePortRequest) -> dict:
    try:
        await service.rename_port(req.mode, req.bay, req.name)
    except Pulse8AdminError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {"result": True}


@app.get("/api/edid-profiles")
async def list_edid_profiles() -> list[dict]:
    return [asdict(p) for p in service.edid_profiles()]


@app.post("/api/ports/edid")
async def set_edid(req: SetEdidRequest) -> dict:
    try:
        await service.set_edid_profile(req.bay, req.profile)
    except Pulse8AdminError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {"result": True}


@app.post("/api/system/backlight")
async def set_backlight(req: SetBacklightRequest) -> dict:
    try:
        await service.set_backlight(req.level)
    except Pulse8AdminError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {"result": True}


@app.post("/api/system/status-led")
async def set_status_led(req: SetStatusLedRequest) -> dict:
    try:
        await service.set_status_led(req.on)
    except Pulse8AdminError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {"result": True}


@app.post("/api/route/by-name")
async def route_by_name(req: RouteByNameRequest) -> dict:
    try:
        result = await service.route_by_name(req.input_name, req.output_name)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except PulseEightError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return result.model_dump(mode="json")


static_dir = Path(__file__).resolve().parent / "static"
app.mount("/", StaticFiles(directory=static_dir, html=True), name="static")
