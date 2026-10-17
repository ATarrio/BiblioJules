"""Jinja2 template environment shared by every router."""

from __future__ import annotations

from datetime import date, datetime
from pathlib import Path

from fastapi.templating import Jinja2Templates

from . import i18n
from .config import settings

TEMPLATES_DIR = Path(__file__).resolve().parent / "templates"

templates = Jinja2Templates(directory=str(TEMPLATES_DIR))
templates.env.globals["app_name"] = settings.app_name
templates.env.globals["current_year"] = date.today().year

# i18n helpers available inside every template: {{ _("Dashboard") }}.
templates.env.globals["_"] = i18n.gettext
templates.env.globals["ngettext"] = i18n.ngettext
templates.env.globals["status_label"] = i18n.status_label
templates.env.globals["status_label_from"] = i18n.status_label_from
templates.env.globals["languages"] = i18n.SUPPORTED_LANGUAGES


def _inject_i18n(request):
    return {"current_language": i18n.get_language()}


templates.context_processors.append(_inject_i18n)


def _format_date(value) -> str:
    if isinstance(value, (datetime, date)):
        return i18n.format_date(value)
    return value or ""


templates.env.filters["date"] = _format_date
