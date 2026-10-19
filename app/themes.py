"""The colour themes shared by the web, desktop and Android front-ends.

``themes.json`` next to this module is the single source of truth. The server
reads it directly; the Android app mirrors it in ``mobile/lib/src/theme.dart``,
which ``mobile/test/theme_sync_test.dart`` keeps in step — the same arrangement
``app/locales`` uses for the string catalogues.

A theme has two halves:

* the **accent**, described as the ``brand`` scale the three stylesheets already
  speak — the ten Tailwind-style shades ``50``…``900``, plus ``ink``, the colour
  of text drawn *on* the accent (white for every theme except yellow, where white
  on ``#ca8a04`` would be unreadable);
* the **surfaces**: the eleven slate steps the apps paint their backgrounds,
  cards and borders with, rotated onto the same hue. The ramp keeps slate's
  lightness at every step — only the hue and a little chroma move — so text and
  borders keep exactly the contrast they had before whichever theme is on.
  ``card`` is the light-mode panel colour (near-white, faintly tinted).

The ``label`` is an English source string on purpose: the screens pass it
through their own translator, so the themes are localised like any other string.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

THEMES_FILE = Path(__file__).resolve().parent / "themes.json"

#: The accent shades a theme must define, lightest first.
SHADES: tuple[int, ...] = (50, 100, 200, 300, 400, 500, 600, 700, 800, 900)
#: The surface steps, matching Tailwind's slate scale.
SURFACE_SHADES: tuple[int, ...] = (50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950)

_HEX = re.compile(r"^#[0-9a-f]{6}$")


@dataclass(frozen=True)
class ColorTheme:
    """One theme: its identity, its accent scale, its ink and its surfaces."""

    slug: str
    label: str
    ink: str
    scale: dict[int, str]
    surface: dict[int, str]
    card: str

    def shade(self, value: int) -> str:
        """The ``#rrggbb`` for one accent shade (``500`` when unsure)."""
        return self.scale.get(value, self.scale[500])

    def surface_shade(self, value: int = 900) -> str:
        """The ``#rrggbb`` for one surface step (``900`` when unsure)."""
        return self.surface.get(value, self.surface[900])

    def css_scale(self) -> dict[str, str]:
        """The accent as a JS-friendly object, ``ink`` included.

        Handed straight to ``tailwind.config`` and, from there, to every
        ``brand-*`` utility class in the templates.
        """
        return {str(shade): self.scale[shade] for shade in SHADES} | {"ink": self.ink}

    def surface_css(self) -> dict[str, object]:
        """CSS custom properties for the surface ramp.

        ``scale`` maps every step to a bare ``r g b`` triplet, which is what
        ``rgb(var(--surface-500) / <alpha-value>)`` expects. ``card`` and
        ``card_dark`` are the two faces of the light-mode panel colour: in dark
        mode the panels fall back to the ``900`` step instead.
        """

        def triplet(hex_color: str) -> str:
            return " ".join(str(int(hex_color[index : index + 2], 16)) for index in (1, 3, 5))

        return {
            "scale": {str(step): triplet(self.surface[step]) for step in SURFACE_SHADES},
            "card": triplet(self.card),
            "card_dark": triplet(self.surface[900]),
        }


def _parse_theme(raw: object, position: int) -> ColorTheme:
    where = f"themes.json theme #{position + 1}"
    if not isinstance(raw, dict):
        raise ValueError(f"{where}: expected an object")
    slug = raw.get("slug")
    label = raw.get("label")
    ink = raw.get("ink")
    scale = raw.get("scale")
    if not isinstance(slug, str) or not slug:
        raise ValueError(f"{where}: missing a slug")
    if not isinstance(label, str) or not label:
        raise ValueError(f"{where} ({slug}): missing a label")
    if not isinstance(ink, str) or not _HEX.match(ink):
        raise ValueError(f"{where} ({slug}): ink must be #rrggbb")
    if not isinstance(scale, dict):
        raise ValueError(f"{where} ({slug}): missing a scale")
    shades: dict[int, str] = {}
    for shade in SHADES:
        value = scale.get(str(shade))
        if not isinstance(value, str) or not _HEX.match(value):
            raise ValueError(f"{where} ({slug}): shade {shade} must be #rrggbb")
        shades[shade] = value

    surface = raw.get("surface")
    if not isinstance(surface, dict):
        raise ValueError(f"{where} ({slug}): missing a surface ramp")
    surface_shades: dict[int, str] = {}
    for step in SURFACE_SHADES:
        value = surface.get(str(step))
        if not isinstance(value, str) or not _HEX.match(value):
            raise ValueError(f"{where} ({slug}): surface {step} must be #rrggbb")
        surface_shades[step] = value
    card = surface.get("card")
    if not isinstance(card, str) or not _HEX.match(card):
        raise ValueError(f"{where} ({slug}): surface card must be #rrggbb")

    return ColorTheme(
        slug=slug,
        label=label,
        ink=ink,
        scale=shades,
        surface=surface_shades,
        card=card,
    )


@lru_cache(maxsize=1)
def _load() -> tuple[str, tuple[ColorTheme, ...]]:
    try:
        with THEMES_FILE.open(encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as error:  # pragma: no cover - packaging mistake
        raise ValueError(f"could not read {THEMES_FILE}: {error}") from error

    raw_themes = data.get("themes") if isinstance(data, dict) else None
    if not isinstance(raw_themes, list) or not raw_themes:
        raise ValueError(f"{THEMES_FILE}: expected a non-empty 'themes' list")

    themes = tuple(_parse_theme(raw, index) for index, raw in enumerate(raw_themes))
    slugs = [theme.slug for theme in themes]
    duplicates = {slug for slug in slugs if slugs.count(slug) > 1}
    if duplicates:
        raise ValueError(f"{THEMES_FILE}: duplicate slugs {sorted(duplicates)}")

    default = data.get("default")
    if default not in slugs:
        raise ValueError(f"{THEMES_FILE}: default {default!r} is not one of {slugs}")
    return default, themes


#: Every theme, in the order the pickers show them (red → gray, around the wheel).
THEMES: tuple[ColorTheme, ...]
#: The theme a fresh install starts on.
DEFAULT_THEME: str
DEFAULT_THEME, THEMES = _load()

#: The slugs, in the same order.
THEME_SLUGS: tuple[str, ...] = tuple(theme.slug for theme in THEMES)


def surface_scale() -> dict[str, str]:
    """Tailwind colour values for the surface ramp.

    Every step points at a CSS custom property (set per theme in ``base.html``),
    so one template class — ``bg-slate-900`` — resolves differently in light and
    dark mode without a second palette.
    """
    return {
        str(step): f"rgb(var(--surface-{step}) / <alpha-value>)"
        for step in SURFACE_SHADES
    }

_BY_SLUG: dict[str, ColorTheme] = {theme.slug: theme for theme in THEMES}


def normalize_theme(slug: str | None) -> str:
    """The stored form of ``slug``: a known slug, or the default."""
    return slug if slug in _BY_SLUG else DEFAULT_THEME


def get_theme(slug: str | None) -> ColorTheme:
    """The theme for ``slug`` — the default when it is missing or unknown."""
    return _BY_SLUG[normalize_theme(slug)]


#: The cookie the browser keeps its theme in (the sibling of ``lang``).
THEME_COOKIE = "color_theme"


def detect_request_theme(request) -> str:
    """Pick a theme from ``?theme=`` or the colour-theme cookie.

    Duck-typed on the request, exactly like ``i18n.detect_request_language``, so
    the desktop app — which has no request at all — can import this module
    without dragging Starlette in.
    """
    query = getattr(request, "query_params", None)
    if query:
        explicit = query.get("theme")
        if explicit:
            return normalize_theme(explicit)

    cookies = getattr(request, "cookies", None)
    if cookies:
        cookie = cookies.get(THEME_COOKIE)
        if cookie:
            return normalize_theme(cookie)
    return DEFAULT_THEME
