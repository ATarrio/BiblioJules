"""Jinja2 template environment shared by every router."""

from __future__ import annotations

from datetime import date, datetime
from pathlib import Path

from fastapi.templating import Jinja2Templates

from . import i18n, themes
from .book_fields import (
    COVER_TYPES,
    READ_STATUSES,
    cover_type_label,
    read_status_label,
    score_label,
)
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
templates.env.globals["themes"] = themes.THEMES
templates.env.globals["cover_types"] = COVER_TYPES
templates.env.globals["read_statuses"] = READ_STATUSES
templates.env.globals["cover_type_label"] = cover_type_label
templates.env.globals["read_status_label"] = read_status_label
templates.env.globals["score_label"] = score_label


def _inject_i18n(request):
    return {"current_language": i18n.get_language()}


templates.context_processors.append(_inject_i18n)


def _inject_theme(request):
    """Expose the browser's colours to every template.

    ``brand_scale`` goes straight into Tailwind's config, so every ``brand-*``
    class in the templates — buttons, links, focus rings, active navigation —
    follows the chosen theme without a single client-side lookup. ``surface_vars``
    does the same for the slate ramp: the accent's hue, at slate's lightness, so
    backgrounds and borders move with the theme and contrast stays where it was.
    """
    theme = themes.get_theme(themes.detect_request_theme(request))
    return {
        "current_theme": theme.slug,
        "brand_scale": theme.css_scale(),
        "surface_vars": theme.surface_css(),
        "surface_scale": themes.surface_scale(),
    }


templates.context_processors.append(_inject_theme)


def _inject_auth(request):
    """Expose the signed-in account and the CSRF value to every template."""
    data = {"current_user": getattr(request.state, "user", None)}
    # A context processor runs *after* the context a route passes, so returning
    # `csrf_token: None` here would silently blank a token the route supplied
    # (which is exactly how the login form once shipped `value="None"`). Only
    # provide the key when there is a value to provide.
    csrf = getattr(request.state, "csrf", None)
    if csrf:
        data["csrf_token"] = csrf
    return data


templates.context_processors.append(_inject_auth)


def _format_date(value) -> str:
    if isinstance(value, (datetime, date)):
        return i18n.format_date(value)
    return value or ""


templates.env.filters["date"] = _format_date
