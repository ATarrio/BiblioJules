"""Small shared helpers for building the desktop UI."""

from __future__ import annotations

from datetime import date, datetime
from typing import Iterable

from PySide6.QtWidgets import (
    QComboBox,
    QFrame,
    QLabel,
    QVBoxLayout,
    QWidget,
)

from .. import i18n
from ..services import library
from ..models import Status
from .theme import rgba


def location_choices(db) -> list[tuple[int, str]]:
    """``[(location_id, "  indented name"), ...]`` in tree order."""
    choices: list[tuple[int, str]] = []
    for location, depth in library.flatten_locations(db):
        label = "    " * depth + location.name
        if location.kind:
            label += f"  ({location.kind})"
        choices.append((location.id, label))
    return choices


def status_choices(db) -> list[tuple[int, str]]:
    """``[(status_id, "icon name"), ...]`` ordered by the service."""
    choices: list[tuple[int, str]] = []
    for status in library.list_statuses(db):
        name = i18n.status_label(status)
        label = f"{status.icon} {name}".strip() if status.icon else name
        choices.append((status.id, label))
    return choices


def fill_combo(
    combo: QComboBox,
    choices: Iterable[tuple[int, str]],
    *,
    none_label: str | None = None,
    current: int | None = None,
) -> None:
    """Repopulate a combo box, optionally with a leading "none" entry."""
    combo.blockSignals(True)
    combo.clear()
    if none_label is not None:
        combo.addItem(none_label, None)
    for value, label in choices:
        combo.addItem(label, value)
    if current is not None:
        index = combo.findData(current)
        if index >= 0:
            combo.setCurrentIndex(index)
    combo.blockSignals(False)


def format_date(value: date | datetime | None) -> str:
    if value is None:
        return ""
    return i18n.format_date(value)


def display_status(status: Status | None) -> str:
    if status is None:
        return ""
    name = i18n.status_label(status)
    return f"{status.icon} {name}".strip() if status.icon else name


# --------------------------------------------------------------------------- #
# Shared UI building blocks (styled via theme.py selectors)
# --------------------------------------------------------------------------- #
def page_header(title: str, subtitle: str = "") -> QWidget:
    """Title + optional subtitle, matching the web app's page headers."""
    container = QWidget()
    layout = QVBoxLayout(container)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(2)
    title_label = QLabel(title)
    title_label.setObjectName("PageTitle")
    layout.addWidget(title_label)
    if subtitle:
        subtitle_label = QLabel(subtitle)
        subtitle_label.setObjectName("PageSubtitle")
        layout.addWidget(subtitle_label)
    return container


def section_title(text: str) -> QLabel:
    label = QLabel(text)
    label.setObjectName("SectionTitle")
    return label


def card() -> QFrame:
    frame = QFrame()
    frame.setObjectName("Card")
    return frame


def style_badge(label: QLabel, text: str, color: str) -> None:
    """Style an existing label as a pill: tinted background, coloured text."""
    label.setText(text)
    label.setStyleSheet(
        f"background-color: {rgba(color, 0.18)}; color: {color};"
        f"border-radius: 9px; padding: 2px 9px; font-weight: bold;"
    )


def badge(text: str, color: str) -> QLabel:
    """A pill like the web app's status badges: tinted background, coloured text."""
    label = QLabel()
    style_badge(label, text, color)
    return label
