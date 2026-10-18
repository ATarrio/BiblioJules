"""Small shared helpers for building the desktop UI."""

from __future__ import annotations

from datetime import date, datetime
from typing import Any, Callable, Iterable

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QAbstractSpinBox,
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QTableWidget,
    QVBoxLayout,
    QWidget,
)

from .. import i18n
from ..book_fields import cover_type_label, read_status_label, score_label
from .theme import rgba


def location_choices(locations: Iterable[dict]) -> list[tuple[int, str]]:
    """``[(location_id, "  indented name"), ...]`` in tree order.

    Takes the flat list from a repo (already in tree order) and derives each
    row's indentation from its ``parent_id`` chain.
    """
    items = list(locations)
    parents = {item.get("id"): item.get("parent_id") for item in items}
    choices: list[tuple[int, str]] = []
    for item in items:
        label = "    " * _tree_depth(item.get("id"), parents) + (item.get("name") or "")
        if item.get("kind"):
            label += f"  ({item['kind']})"
        choices.append((item.get("id"), label))
    return choices


def _tree_depth(node_id: Any, parents: dict) -> int:
    """How many ancestors ``node_id`` has (cycle-safe)."""
    depth = 0
    seen: set = set()
    current = parents.get(node_id)
    while current is not None and current not in seen:
        seen.add(current)
        depth += 1
        current = parents.get(current)
    return depth


def status_choices(statuses: Iterable[dict]) -> list[tuple[int, str]]:
    """``[(status_id, "icon name"), ...]`` in the order the repo returned."""
    choices: list[tuple[int, str]] = []
    for status in statuses:
        name = i18n.status_label_from(status.get("slug"), status.get("name"))
        icon = status.get("icon")
        label = f"{icon} {name}".strip() if icon else name
        choices.append((status.get("id"), label))
    return choices


def default_status_id(statuses: Iterable[dict]) -> int | None:
    """The id of the status a new book should get, mirroring the service layer."""
    items = list(statuses)
    for status in items:
        if status.get("is_default"):
            return status.get("id")
    for status in items:
        if status.get("slug") == "available":
            return status.get("id")
    return items[0].get("id") if items else None


def fill_combo(
    combo: QComboBox,
    choices: Iterable[tuple[Any, str]],
    *,
    none_label: str | None = None,
    current: Any | None = None,
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


def format_date(value: date | datetime | str | None) -> str:
    """Format a date, accepting the ISO strings the repo layer returns."""
    if value is None:
        return ""
    if isinstance(value, str):
        parsed = _parse_iso_date(value)
        if parsed is None:
            return ""
        value = parsed
    return i18n.format_date(value)


def _parse_iso_date(value: str) -> date | None:
    text = value.strip()
    if not text:
        return None
    try:
        return date.fromisoformat(text[:10])
    except ValueError:
        return None


def display_status(status: dict | None) -> str:
    if not status:
        return ""
    name = i18n.status_label_from(status.get("slug"), status.get("name"))
    icon = status.get("icon")
    return f"{icon} {name}".strip() if icon else name


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


def spin_stepper(spin: QAbstractSpinBox, *, width: int = 84) -> QWidget:
    """Wrap a spin box with visible − / + buttons.

    The theme hides the native up/down arrows, so these are the mouse-friendly
    way to change the value. The wrapper keeps the control compact in a form.
    """
    spin.setFixedWidth(width)
    row = QHBoxLayout()
    row.setContentsMargins(0, 0, 0, 0)
    row.setSpacing(6)
    row.addWidget(_step_button("−", spin.stepDown))
    row.addWidget(spin)
    row.addWidget(_step_button("+", spin.stepUp))
    row.addStretch(1)

    container = QWidget()
    container.setLayout(row)
    return container


def _step_button(label: str, slot) -> QPushButton:
    button = QPushButton(label)
    button.setProperty("variant", "ghost")
    button.setFixedSize(32, 30)
    button.setStyleSheet("padding: 0; font-size: 16px; font-weight: 700;")
    button.setAutoRepeat(True)
    button.setAutoRepeatDelay(350)
    button.setAutoRepeatInterval(80)
    button.setFocusPolicy(Qt.FocusPolicy.NoFocus)
    button.clicked.connect(lambda: slot())
    return button


class ColumnSort:
    """Clickable table headers that sort a view's rows, toggling direction.

    Views keep their rows in a list and re-render whenever this changes; the
    class only tracks the active column and direction and can order a list of
    rows using the per-column key functions it was given.
    """

    def __init__(
        self,
        table: QTableWidget,
        keys: dict[int, Callable[[Any], Any]],
        on_change: Callable[[], None],
    ) -> None:
        self._table = table
        self._keys = keys
        self._on_change = on_change
        self.column = -1
        self.descending = False
        header = table.horizontalHeader()
        header.setSectionsClickable(True)
        header.setSortIndicatorShown(False)
        header.sectionClicked.connect(self.select)

    def select(self, column: int) -> None:
        """Sort by ``column``; clicking the active column flips the direction."""
        if column not in self._keys:
            return
        if column == self.column:
            self.descending = not self.descending
        else:
            self.column = column
            self.descending = False
        self._update_indicator()
        self._on_change()

    def clear(self) -> None:
        self.column = -1
        self.descending = False
        self._update_indicator()

    def apply(self, rows: list[Any]) -> list[Any]:
        """Return ``rows`` ordered according to the active column."""
        if self.column < 0:
            return rows
        return sorted(rows, key=self._keys[self.column], reverse=self.descending)

    def _update_indicator(self) -> None:
        header = self._table.horizontalHeader()
        if self.column < 0:
            header.setSortIndicatorShown(False)
            return
        header.setSortIndicatorShown(True)
        header.setSortIndicator(
            self.column,
            Qt.SortOrder.DescendingOrder if self.descending else Qt.SortOrder.AscendingOrder,
        )


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
