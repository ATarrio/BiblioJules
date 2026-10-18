"""Fixed vocabularies for book attributes, and their translated labels.

Cover type and read status are stored as stable slugs so the UI can be
translated; the English label is the translation key (see :mod:`app.i18n`).
"""

from __future__ import annotations

from .i18n import _

#: (slug, English label) — the label is what appears in ``app/locales/*.json``.
COVER_TYPES: list[tuple[str, str]] = [
    ("hardcover", "Hardcover"),
    ("paperback", "Paperback"),
    ("ebook", "Ebook"),
    ("audiobook", "Audiobook"),
    ("pocket", "Pocket"),
    ("other", "Other"),
]

READ_STATUSES: list[tuple[str, str]] = [
    ("unread", "Unread"),
    ("to_read", "To Be Read"),
    ("currently_reading", "Currently Reading"),
    ("read", "Read"),
    ("dnf", "DNF"),
]

COVER_TYPE_SLUGS: set[str] = {slug for slug, _label in COVER_TYPES}
READ_STATUS_SLUGS: set[str] = {slug for slug, _label in READ_STATUSES}
_COVER_TYPE_LABELS: dict[str, str] = dict(COVER_TYPES)
_READ_STATUS_LABELS: dict[str, str] = dict(READ_STATUSES)

#: A score runs from one to five stars, in half-star steps.
MIN_SCORE = 1.0
MAX_SCORE = 5.0
SCORE_STEP = 0.5


def cover_type_label(slug: str | None) -> str:
    source = _COVER_TYPE_LABELS.get(slug or "")
    return _(source) if source else ""


def read_status_label(slug: str | None) -> str:
    source = _READ_STATUS_LABELS.get(slug or "")
    return _(source) if source else ""


def score_label(score: float | None) -> str:
    """Render a score as filled/half/empty stars, e.g. ``★★★½☆``."""
    if not score:
        return ""
    score = float(score)
    full = int(score)
    half = (score - full) >= SCORE_STEP
    return "★" * full + ("½" if half else "") + "☆" * (5 - full - (1 if half else 0))
