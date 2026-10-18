"""Pydantic schemas for the JSON API (``/api/...``)."""

from __future__ import annotations

from datetime import date

from pydantic import BaseModel, ConfigDict


class BookIn(BaseModel):
    """Payload accepted when creating/updating a book through the API."""

    model_config = ConfigDict(extra="ignore")

    isbn: str | None = None
    title: str | None = None
    subtitle: str | None = None
    #: A list of names, or a comma-separated string (handy for form-style clients).
    authors: list[str] | str | None = None
    publisher: str | None = None
    published_date: str | None = None
    description: str | None = None
    page_count: int | None = None
    language: str | None = None
    cover_url: str | None = None
    cover_type: str | None = None
    read_status: str | None = None
    score: float | None = None
    saga: str | None = None
    saga_number: int | None = None
    location_id: int | None = None
    status_id: int | None = None
    notes: str | None = None
    source: str | None = None


class LocationIn(BaseModel):
    name: str
    parent_id: int | None = None
    kind: str | None = None
    description: str | None = None


class StatusIn(BaseModel):
    name: str
    color: str = "#64748b"
    icon: str | None = None
    description: str | None = None


class LoanIn(BaseModel):
    borrower_name: str
    borrower_contact: str | None = None
    lent_at: date | None = None
    due_at: date | None = None
    notes: str | None = None
    mark_status: bool = True


class ReturnIn(BaseModel):
    returned_at: date | None = None
    restore_status: bool = True


# --------------------------------------------------------------------------- #
# Authentication / accounts
# --------------------------------------------------------------------------- #
class LoginIn(BaseModel):
    model_config = ConfigDict(extra="ignore")

    username: str
    password: str
    #: Optional note identifying the device/token ("Pixel 8", "laptop").
    label: str | None = None


class UserIn(BaseModel):
    model_config = ConfigDict(extra="ignore")

    username: str
    password: str
    role: str = "member"
    display_name: str | None = None


class UserUpdateIn(BaseModel):
    model_config = ConfigDict(extra="ignore")

    display_name: str | None = None
    role: str | None = None
    is_active: bool | None = None
    password: str | None = None
