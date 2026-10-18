"""Discover view: search online catalogues and add books to the wishlist."""

from __future__ import annotations

from typing import Callable

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QAbstractItemView,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from .. import i18n
from ..i18n import _
from ..services.isbn_lookup import search_books
from .repo import get_repo
from .util import ColumnSort, card, page_header
from .workers import run_async

_RESULT = Qt.ItemDataRole.UserRole


class DiscoverView(QWidget):
    def __init__(self, on_change: Callable[[], None], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.on_change = on_change
        self._build_ui()

    def _build_ui(self) -> None:
        self.query = QLineEdit()
        self.query.setPlaceholderText(_("Search Open Library / Google Books by title or author…"))
        self.query.returnPressed.connect(self._search)
        self.search_btn = QPushButton(_("Search"))
        self.search_btn.setProperty("variant", "primary")
        self.search_btn.clicked.connect(self._search)

        search_card = card()
        search_row = QHBoxLayout(search_card)
        search_row.setContentsMargins(14, 12, 14, 12)
        search_row.setSpacing(10)
        search_row.addWidget(self.query, 1)
        search_row.addWidget(self.search_btn)

        self.message = QLabel(_("Find books you don't own yet and add them to your wishlist."))
        self.message.setObjectName("Dim")

        self.table = QTableWidget(0, 5)
        self.table.setHorizontalHeaderLabels(
            [_("Title"), _("Authors"), _("Year"), _("Publisher"), _("Source")]
        )
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setAlternatingRowColors(True)
        self.table.setShowGrid(False)
        self.table.verticalHeader().setVisible(False)
        self.table.verticalHeader().setDefaultSectionSize(38)
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.table.itemDoubleClicked.connect(lambda *_: self._add_selected())

        # Clicking a column header orders the results (again to flip the direction).
        self._rows: list[dict] = []
        self._sort = ColumnSort(
            self.table,
            {
                0: lambda row: (row.get("title") or "").casefold(),
                1: lambda row: ", ".join(row.get("authors") or []).casefold(),
                2: lambda row: (row.get("published_year") is None, row.get("published_year") or 0),
                3: lambda row: (row.get("publisher") or "").casefold(),
                4: lambda row: (row.get("source") or "").casefold(),
            },
            self._render_rows,
        )

        add_btn = QPushButton("＋  " + _("Add selected to wishlist"))
        add_btn.setProperty("variant", "primary")
        add_btn.clicked.connect(self._add_selected)

        actions = QHBoxLayout()
        actions.addWidget(add_btn)
        actions.addStretch(1)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 24, 28, 24)
        layout.setSpacing(16)
        layout.addWidget(
            page_header(
                _("Discover"),
                _("Search the online catalogues and add books you want to buy to your wishlist."),
            )
        )
        layout.addWidget(search_card)
        layout.addWidget(self.message)
        layout.addWidget(self.table, 1)
        layout.addLayout(actions)

    def refresh(self) -> None:
        # Nothing to reload from the database; results are transient.
        pass

    # -- search ------------------------------------------------------------- #
    def _search(self) -> None:
        query = self.query.text().strip()
        if not query:
            return
        self.search_btn.setEnabled(False)
        self.message.setText(_("Searching for “%s”…") % query)
        self._rows = []
        self.table.setRowCount(0)
        run_async(search_books, self._on_results, self._on_error, query)

    def _on_results(self, results: list[dict]) -> None:
        self.search_btn.setEnabled(True)
        if not results:
            self._rows = []
            self.message.setText(_("No matches found."))
            return
        count = len(results)
        self.message.setText(
            i18n.ngettext("%d match found. Double-click to add one.",
                          "%d matches found. Double-click to add one.", count) % count
        )
        self._rows = results
        self._render_rows()

    def _render_rows(self) -> None:
        rows = self._sort.apply(self._rows)
        self.table.setRowCount(len(rows))
        for row_index, result in enumerate(rows):
            values = [
                result.get("title") or _("(untitled)"),
                ", ".join(result.get("authors") or []),
                str(result.get("published_year") or ""),
                result.get("publisher") or "",
                result.get("source") or "",
            ]
            for column, text in enumerate(values):
                item = QTableWidgetItem(text)
                if column == 0:
                    item.setData(_RESULT, result)
                self.table.setItem(row_index, column, item)

    def _on_error(self, message: str) -> None:
        self.search_btn.setEnabled(True)
        self.message.setText(_("Search failed: %s") % message)

    # -- add ---------------------------------------------------------------- #
    def _add_selected(self) -> None:
        row = self.table.currentRow()
        if row < 0:
            QMessageBox.information(self, _("No selection"), _("Select a search result first."))
            return
        item = self.table.item(row, 0)
        result = item.data(_RESULT) if item else None
        if not result:
            return

        repo = get_repo()
        try:
            existing = repo.find_by_isbn(result.get("isbn") or "")
            wishlist = repo.status_by_slug("wishlist")
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not add"), str(exc))
            return

        if existing is not None:
            QMessageBox.information(
                self,
                _("Already in catalog"),
                _("“%s” is already in your library.") % (existing.get("title") or ""),
            )
            return

        data = {
            "isbn": result.get("isbn") or "",
            "title": result.get("title") or "",
            "subtitle": result.get("subtitle") or "",
            "authors": result.get("authors") or [],
            "publisher": result.get("publisher") or "",
            "published_date": result.get("published_date") or "",
            "published_year": result.get("published_year"),
            "page_count": result.get("page_count"),
            "language": result.get("language") or "",
            "cover_url": result.get("cover_url") or "",
            "description": result.get("description") or "",
            "source": result.get("source") or "manual",
        }
        if wishlist is not None:
            data["status_id"] = wishlist.get("id")
        try:
            repo.create_book(data)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not add"), str(exc))
            return

        self.message.setText(_("Added to your wishlist."))
        self.on_change()
