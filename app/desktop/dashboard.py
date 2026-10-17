"""Dashboard view: headline numbers, status breakdown and recent books."""

from __future__ import annotations

from typing import Callable

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QMouseEvent
from PySide6.QtWidgets import (
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QScrollArea,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from .db import session_scope
from .dialogs import BookDetailsDialog
from .theme import AMBER, BRAND_500, EMERALD, VIOLET
from .util import badge, card, page_header, section_title
from .. import i18n
from ..i18n import _
from ..services import library
from ..services.serializers import book_to_dict

_COLUMNS = 4


def _clear(layout) -> None:
    while layout.count():
        item = layout.takeAt(0)
        widget = item.widget()
        if widget is not None:
            # Unparent immediately so the old widget stops painting this frame
            # (deleteLater alone can leave ghosts until the event loop runs).
            widget.setParent(None)
            widget.deleteLater()


def _stat_card(icon: str, label: str, color: str) -> tuple[QFrame, QLabel]:
    frame = card()
    value = QLabel("0")
    value.setObjectName("StatValue")
    value.setStyleSheet(f"color: {color};")
    caption = QLabel(label)
    caption.setObjectName("StatLabel")
    caption.setWordWrap(True)
    icon_label = QLabel(icon)
    icon_label.setObjectName("StatIcon")

    text_col = QVBoxLayout()
    text_col.setSpacing(0)
    text_col.addWidget(value)
    text_col.addWidget(caption)

    row = QHBoxLayout(frame)
    row.setContentsMargins(18, 16, 18, 16)
    row.addLayout(text_col)
    row.addStretch(1)
    row.addWidget(icon_label)
    return frame, value


class BookCard(QFrame):
    """A dashboard book tile; double-clicking it opens the details dialog."""

    activated = Signal(int)

    def __init__(self, book_id: int, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.book_id = book_id
        self.setObjectName("BookCard")
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setToolTip(_("Double-click for details"))

    def mouseDoubleClickEvent(self, event: QMouseEvent) -> None:  # noqa: N802 (Qt naming)
        self.activated.emit(self.book_id)
        super().mouseDoubleClickEvent(event)


class DashboardView(QWidget):
    def __init__(self, on_change: Callable[[], None], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.on_change = on_change
        self._values: dict[str, QLabel] = {}

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        content = QWidget()
        content.setObjectName("PageContent")
        scroll.setWidget(content)
        outer.addWidget(scroll)

        layout = QVBoxLayout(content)
        layout.setContentsMargins(28, 24, 28, 24)
        layout.setSpacing(20)
        layout.addWidget(
            page_header(_("Your library"), _("Scan a book to add it, or browse your shelves below."))
        )

        # --- stat cards --------------------------------------------------- #
        cards_row = QGridLayout()
        cards_row.setSpacing(16)
        specs = [
            ("library", _("In the library"), "📚", BRAND_500),
            ("loans", _("Lent out"), "🤝", AMBER),
            ("wishlist", _("Wishlist"), "⭐", VIOLET),
            ("authors", _("Authors"), "✍️", EMERALD),
        ]
        for column, (key, label, icon, color) in enumerate(specs):
            frame, value = _stat_card(icon, label, color)
            self._values[key] = value
            cards_row.addWidget(frame, 0, column)
        layout.addLayout(cards_row)

        # --- by status ---------------------------------------------------- #
        layout.addWidget(section_title(_("By status")))
        status_host = QWidget()
        self._status_grid = QGridLayout(status_host)
        self._status_grid.setContentsMargins(0, 0, 0, 0)
        self._status_grid.setSpacing(8)
        layout.addWidget(status_host)

        # --- recently added ----------------------------------------------- #
        layout.addWidget(section_title(_("Recently added")))
        recent_card = card()
        self._recent_grid = QGridLayout(recent_card)
        self._recent_grid.setContentsMargins(16, 16, 16, 16)
        self._recent_grid.setSpacing(12)
        layout.addWidget(recent_card)
        layout.addStretch(1)

    # ------------------------------------------------------------------ #
    def refresh(self) -> None:
        with session_scope() as db:
            stats = library.get_stats(db)
            counts = library.status_counts(db)
            recent = [book_to_dict(book) for book in library.query_books(db, sort="recent")[:8]]

        library_count = stats["total"] - stats["wishlist"]
        if library_count < 0:
            library_count = stats["total"]
        self._values["library"].setText(str(library_count))
        self._values["loans"].setText(str(stats["loans"]))
        self._values["wishlist"].setText(str(stats["wishlist"]))
        self._values["authors"].setText(str(stats["authors"]))

        self._fill_statuses(counts)
        self._fill_recent(recent)

    def _open_details(self, book_id: int) -> None:
        BookDetailsDialog(self, book_id=book_id, on_change=self.on_change).exec()

    def _fill_statuses(self, counts) -> None:
        _clear(self._status_grid)
        if not counts:
            self._status_grid.addWidget(QLabel(_("No statuses yet.")), 0, 0)
            return
        for index, (status, count) in enumerate(counts):
            chip = QFrame()
            chip.setStyleSheet(
                "QFrame { background-color: #0f172a; border: 1px solid #1e293b;"
                " border-radius: 16px; }"
            )
            chip.setSizePolicy(QSizePolicy.Policy.Maximum, QSizePolicy.Policy.Fixed)
            row = QHBoxLayout(chip)
            row.setContentsMargins(12, 6, 12, 6)
            row.setSpacing(8)
            dot = QLabel()
            dot.setFixedSize(10, 10)
            dot.setStyleSheet(f"background-color: {status.color}; border-radius: 5px;")
            name_text = i18n.status_label(status)
            name = QLabel(f"{status.icon} {name_text}".strip() if status.icon else name_text)
            name.setStyleSheet("color: #e2e8f0; border: none; background: transparent;")
            tally = QLabel(str(count))
            tally.setStyleSheet(
                "color: #94a3b8; background-color: #1e293b; border-radius: 9px;"
                " padding: 1px 8px; border: none;"
            )
            row.addWidget(dot)
            row.addWidget(name)
            row.addWidget(tally)
            self._status_grid.addWidget(
                chip, index // _COLUMNS, index % _COLUMNS, alignment=Qt.AlignmentFlag.AlignLeft
            )

    def _fill_recent(self, recent: list[dict]) -> None:
        _clear(self._recent_grid)
        if not recent:
            empty = QLabel(_("📖  No books yet — add one from the Catalog tab."))
            empty.setObjectName("Muted")
            self._recent_grid.addWidget(empty, 0, 0)
            return
        for index, row in enumerate(recent):
            self._recent_grid.addWidget(self._book_card(row), index // _COLUMNS, index % _COLUMNS)

    def _book_card(self, row: dict) -> QFrame:
        frame = BookCard(row["id"])
        frame.activated.connect(self._open_details)
        layout = QVBoxLayout(frame)
        layout.setContentsMargins(14, 12, 14, 12)
        layout.setSpacing(4)

        status = row.get("status")
        title = QLabel(row.get("title") or _("Untitled"))
        title.setStyleSheet("font-weight: bold; color: #f8fafc; background: transparent;")
        title.setWordWrap(True)

        top = QHBoxLayout()
        top.addWidget(title, 1)
        if status and status.get("name"):
            top.addWidget(
                badge(
                    i18n.status_label_from(status.get("slug"), status.get("name")),
                    status.get("color") or "#64748b",
                ),
                0,
            )

        authors = QLabel(", ".join(row.get("authors") or []) or _("Unknown author"))
        authors.setObjectName("Muted")
        authors.setWordWrap(True)

        layout.addLayout(top)
        layout.addWidget(authors)

        facts: list[str] = []
        if row.get("published_year"):
            facts.append(str(row["published_year"]))
        location = (row.get("location") or {}).get("full_path")
        if location:
            facts.append(f"📍 {location}")
        loan = row.get("active_loan")
        if loan:
            facts.append(f"🤝 {loan['borrower_name']}")
        if facts:
            meta = QLabel("  ·  ".join(facts))
            meta.setObjectName("Dim")
            meta.setWordWrap(True)
            layout.addWidget(meta)
        # Let clicks fall through to the card itself, wherever they land.
        for label in frame.findChildren(QLabel):
            label.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        return frame
