"""Request/response schemas owned by this app (device models come straight from
pulse_eight_matrix_client, which is already pydantic v2)."""

from typing import Literal

from pydantic import BaseModel, Field

from .pulse8_admin import BACKLIGHT_LEVELS, MAX_NAME_LENGTH


class RenamePortRequest(BaseModel):
    mode: Literal["Input", "Output"]
    bay: int
    name: str = Field(min_length=1, max_length=MAX_NAME_LENGTH)


class SetEdidRequest(BaseModel):
    bay: int
    profile: int


class SetBacklightRequest(BaseModel):
    level: Literal[BACKLIGHT_LEVELS]


class SetStatusLedRequest(BaseModel):
    on: bool


class RouteRequest(BaseModel):
    input_bay: int
    output_bay: int


class RouteByNameRequest(BaseModel):
    input_name: str
    output_name: str


class PortUpdateInfo(BaseModel):
    bay: int
    name: str
    firmware_version: str | None = None
    firmware_version_available: bool = False
