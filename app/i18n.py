"""Internationalisation (i18n) shared by the web and desktop apps.

English is the *source* language and the default. Translations live next to
this module in ``app/locales/<code>.json`` as simple ``{source: translation}``
maps, so a catalog is just an editable text file: nothing has to be compiled.

A translation value is either a plain string, or an object with ``one`` / ``other``
keys for plurals (see :meth:`Translator.ngettext`). Because English is the
source, ``en.json`` is not required — an unknown key falls back to the English
text written in the code.

The active language is kept in a :class:`contextvars.ContextVar`, so concurrent
web requests (or a desktop session) can each render in their own language. The
web app sets it per request through :class:`LanguageMiddleware`; the desktop app
sets it once at start-up (and again when the user switches language).
"""

from __future__ import annotations

import json
from contextvars import ContextVar
from datetime import date, datetime
from pathlib import Path
from typing import Any

DEFAULT_LANGUAGE = "en"

#: Language code -> name *in that language* (used by the language switcher).
SUPPORTED_LANGUAGES: dict[str, str] = {
    "en": "English",
    "es-419": "Español (Latinoamérica)",
}

#: Rough Accept-Language / cookie aliases mapped onto the codes we ship.
_ALIASES: dict[str, str] = {
    "en": "en",
    "en-us": "en",
    "en-gb": "en",
    "en-ca": "en",
    "en-au": "en",
    "es": "es-419",
    "es-419": "es-419",
    "es-mx": "es-419",
    "es-ar": "es-419",
    "es-co": "es-419",
    "es-cl": "es-419",
    "es-pe": "es-419",
    "es-ve": "es-419",
    "es-uy": "es-419",
}

LOCALES_DIR = Path(__file__).resolve().parent / "locales"

# Names the app seeds for its built-in statuses. Kept here (keyed by slug) so the
# UI can show a translated name without ever touching the database: a status the
# user has renamed keeps its own name.
SYSTEM_STATUS_NAMES: dict[str, str] = {
    "available": "In library",
    "reading": "Reading",
    "lent": "Lent out",
    "wishlist": "Wishlist",
    "lost": "Lost",
    "donated": "Donated",
}

_MONTHS: dict[str, list[str]] = {
    "en": ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
    "es-419": [
        "ene", "feb", "mar", "abr", "may", "jun",
        "jul", "ago", "sep", "oct", "nov", "dic",
    ],
}

_CATALOG_CACHE: dict[str, dict[str, Any]] = {}
_EMPTY_CATALOG: dict[str, Any] = {}


# --------------------------------------------------------------------------- #
# Language codes
# --------------------------------------------------------------------------- #
def normalize_language(code: str | None) -> str:
    """Map any language tag (``es_MX``, ``es-AR``, ``en`` …) to a supported code."""
    if not code:
        return DEFAULT_LANGUAGE
    code = code.strip().lower().replace("_", "-")
    if code in _ALIASES:
        return _ALIASES[code]
    if code in SUPPORTED_LANGUAGES:
        return code
    base = code.split("-", 1)[0]
    if base == "en":
        return "en"
    if base == "es":
        return "es-419"
    return DEFAULT_LANGUAGE


def is_supported(code: str | None) -> bool:
    return normalize_language(code) in SUPPORTED_LANGUAGES


def load_catalog(language: str) -> dict[str, Any]:
    language = normalize_language(language)
    if language in _CATALOG_CACHE:
        return _CATALOG_CACHE[language]
    catalog: dict[str, Any] = _EMPTY_CATALOG
    if language != DEFAULT_LANGUAGE:
        path = LOCALES_DIR / f"{language}.json"
        if path.exists():
            with path.open(encoding="utf-8") as handle:
                catalog = json.load(handle)
    _CATALOG_CACHE[language] = catalog
    return catalog


# --------------------------------------------------------------------------- #
# Translation
# --------------------------------------------------------------------------- #
class Translator:
    """Looks a message up in one catalog and returns the best translation."""

    def __init__(self, language: str | None = None) -> None:
        self.language = normalize_language(language)
        self.catalog = load_catalog(self.language)

    # Backwards-friendly aliases so it can be dropped in for gettext().
    def gettext(self, message: str, **params: Any) -> str:
        entry = self.catalog.get(message)
        text = entry if isinstance(entry, str) else message
        return _interpolate(text, params)

    # gettext() also calls it this way.
    def _(self, message: str, **params: Any) -> str:  # noqa: N802 (gettext name)
        return self.gettext(message, **params)

    def ngettext(self, singular: str, plural: str, n: int, **params: Any) -> str:
        entry = self.catalog.get(singular)
        if isinstance(entry, dict):
            key = "one" if n == 1 else "other"
            text = entry.get(key) or entry.get("other") or singular
        elif isinstance(entry, str):
            text = entry
        else:
            text = singular if n == 1 else plural
        return _interpolate(text, params)

    def format_date(self, value: date | datetime | None) -> str:
        if value is None:
            return ""
        if isinstance(value, datetime):
            value = value.date()
        months = _MONTHS.get(self.language, _MONTHS["en"])
        return f"{value.day} {months[value.month - 1]} {value.year}"

    def status_label(self, status) -> str:
        slug = getattr(status, "slug", None)
        name = getattr(status, "name", "") or ""
        return self.status_label_from(slug, name)

    def status_label_from(self, slug: str | None, name: str | None) -> str:
        name = name or ""
        source = SYSTEM_STATUS_NAMES.get(slug or "")
        # Only translate the built-in name; a user's rename is shown verbatim.
        if source is not None and name == source:
            return self.gettext(source)
        return name


def _interpolate(text: str, params: dict[str, Any]) -> str:
    if not params:
        return text
    try:
        return text % params
    except (KeyError, TypeError, ValueError):
        pass
    try:
        return text.format(**params)
    except (KeyError, IndexError, ValueError):
        return text


# --------------------------------------------------------------------------- #
# Active translator (per request / per session)
# --------------------------------------------------------------------------- #
_default_translator = Translator(DEFAULT_LANGUAGE)
_current: ContextVar[Translator] = ContextVar("bibliotheque_translator")


def get_translator() -> Translator:
    return _current.get(_default_translator)


def get_language() -> str:
    return get_translator().language


def set_language(code: str | None) -> str:
    """Switch the active language for the current context; returns the code."""
    translator = Translator(code)
    _current.set(translator)
    return translator.language


def gettext(message: str, **params: Any) -> str:
    return get_translator().gettext(message, **params)


# A conventional short alias: ``_("Dashboard")``.
_ = gettext


def ngettext(singular: str, plural: str, n: int, **params: Any) -> str:
    return get_translator().ngettext(singular, plural, n, **params)


def format_date(value: date | datetime | None) -> str:
    return get_translator().format_date(value)


def status_label(status) -> str:
    return get_translator().status_label(status)


def status_label_from(slug: str | None, name: str | None) -> str:
    return get_translator().status_label_from(slug, name)


# --------------------------------------------------------------------------- #
# Web request language detection
# --------------------------------------------------------------------------- #
def _iter_accept_language(header: str):
    for part in (header or "").split(","):
        code = part.split(";", 1)[0].strip().lower()
        if code:
            yield code


def detect_request_language(request) -> str:
    """Pick a language from ``?lang=``, the ``lang`` cookie or ``Accept-Language``."""
    query = getattr(request, "query_params", None)
    if query:
        explicit = query.get("lang")
        if explicit:
            return normalize_language(explicit)

    cookies = getattr(request, "cookies", None)
    if cookies:
        cookie = cookies.get("lang")
        if cookie:
            return normalize_language(cookie)

    headers = getattr(request, "headers", None)
    header = headers.get("accept-language", "") if headers else ""
    for code in _iter_accept_language(header):
        if code.startswith("en") or code.startswith("es"):
            return normalize_language(code)
    return DEFAULT_LANGUAGE


def catalog_keys(language: str) -> set[str]:
    """Every source string known to a catalog (used by tests / maintenance)."""
    return set(load_catalog(language).keys())


# --------------------------------------------------------------------------- #
# ASGI middleware
# --------------------------------------------------------------------------- #
class LanguageMiddleware:
    """Set the active language for each request from its headers / cookie.

    Written as a plain ASGI middleware (not ``BaseHTTPMiddleware``) so the
    context variable it sets is inherited by everything downstream, including
    the templates rendered inside the route handlers.
    """

    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        from starlette.requests import Request

        request = Request(scope)
        token = _current.set(Translator(detect_request_language(request)))
        try:
            await self.app(scope, receive, send)
        finally:
            _current.reset(token)
