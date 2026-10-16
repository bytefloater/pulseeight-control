"""Connection settings for the matrix device, read from a JSON file on disk.

There is no API or UI to change these at runtime — edit config.json (see
config.example.json) and restart the server.
"""

import json
import logging
from pathlib import Path

from pydantic import BaseModel

_LOGGER = logging.getLogger(__name__)

CONFIG_PATH = Path(__file__).resolve().parent.parent / "config.json"


class MatrixConfig(BaseModel):
    host: str | None = None
    port: int = 80
    timeout: int = 10
    poll_interval: int = 5
    detail_poll_interval: int = 20
    # Required to rename ports (POST /Account/Login on the matrix). Not
    # needed for routing/read-only use.
    admin_password: str | None = None


def load_config(path: Path = CONFIG_PATH) -> MatrixConfig:
    if not path.exists():
        _LOGGER.warning("No config.json found at %s; matrix is unconfigured", path)
        return MatrixConfig()
    try:
        return MatrixConfig.model_validate(json.loads(path.read_text()))
    except (json.JSONDecodeError, ValueError) as exc:
        _LOGGER.error("Failed to parse %s: %s", path, exc)
        return MatrixConfig()
