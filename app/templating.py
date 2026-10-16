"""Jinja2 template environment shared by every router."""

from __future__ import annotations

from datetime import date, datetime
from pathlib import Path

from fastapi.templating import Jinja2Templates

from .config import settings

TEMPLATES_DIR = Path(__file__).resolve().parent / "templates"

templates = Jinja2Templates(directory=str(TEMPLATES_DIR))
templates.env.globals["app_name"] = settings.app_name
templates.env.globals["current_year"] = date.today().year


def _format_date(value) -> str:
    if isinstance(value, datetime):
        return value.strftime("%d %b %Y")
    if isinstance(value, date):
        return value.strftime("%d %b %Y")
    return value or ""


templates.env.filters["date"] = _format_date
