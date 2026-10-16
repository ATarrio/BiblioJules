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
    authors: list[str] | None = None
    publisher: str | None = None
    published_date: str | None = None
    published_year: int | None = None
    description: str | None = None
    page_count: int | None = None
    language: str | None = None
    cover_url: str | None = None
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
