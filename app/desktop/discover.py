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

from ..services import library
from ..services.isbn_lookup import search_books
from .db import session_scope
from .util import card, page_header
from .workers import run_async

_RESULT = Qt.ItemDataRole.UserRole


class DiscoverView(QWidget):
    def __init__(self, on_change: Callable[[], None], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.on_change = on_change
        self._build_ui()

    def _build_ui(self) -> None:
        self.query = QLineEdit()
        self.query.setPlaceholderText("Search Open Library / Google Books by title or author…")
        self.query.returnPressed.connect(self._search)
        self.search_btn = QPushButton("Search")
        self.search_btn.setProperty("variant", "primary")
        self.search_btn.clicked.connect(self._search)

        search_card = card()
        search_row = QHBoxLayout(search_card)
        search_row.setContentsMargins(14, 12, 14, 12)
        search_row.setSpacing(10)
        search_row.addWidget(self.query, 1)
        search_row.addWidget(self.search_btn)

        self.message = QLabel("Find books you don't own yet and add them to your wishlist.")
        self.message.setObjectName("Dim")

        self.table = QTableWidget(0, 5)
        self.table.setHorizontalHeaderLabels(["Title", "Authors", "Year", "Publisher", "Source"])
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setAlternatingRowColors(True)
        self.table.setShowGrid(False)
        self.table.verticalHeader().setVisible(False)
        self.table.verticalHeader().setDefaultSectionSize(38)
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.table.itemDoubleClicked.connect(lambda *_: self._add_selected())

        add_btn = QPushButton("＋  Add selected to wishlist")
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
                "Discover",
                "Search the online catalogues and add books you want to buy to your wishlist.",
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
        self.message.setText(f"Searching for “{query}”…")
        self.table.setRowCount(0)
        run_async(search_books, self._on_results, self._on_error, query)

    def _on_results(self, results: list[dict]) -> None:
        self.search_btn.setEnabled(True)
        if not results:
            self.message.setText("No matches found.")
            return
        self.message.setText(f"{len(results)} match(es) found. Double-click to add one.")
        self.table.setRowCount(len(results))
        for row_index, result in enumerate(results):
            values = [
                result.get("title") or "(untitled)",
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
        self.message.setText(f"Search failed: {message}")

    # -- add ---------------------------------------------------------------- #
    def _add_selected(self) -> None:
        row = self.table.currentRow()
        if row < 0:
            QMessageBox.information(self, "No selection", "Select a search result first.")
            return
        item = self.table.item(row, 0)
        result = item.data(_RESULT) if item else None
        if not result:
            return

        with session_scope() as db:
            existing = library.find_by_isbn(db, result.get("isbn") or "")
            if existing is not None:
                QMessageBox.information(
                    self, "Already in catalog", f"“{existing.title}” is already in your library."
                )
                return
            wishlist = library.get_status_by_slug(db, "wishlist")
            status_id = wishlist.id if wishlist else None
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
            if status_id is not None:
                data["status_id"] = status_id
            try:
                library.create_book(db, data)
            except Exception as exc:  # noqa: BLE001
                QMessageBox.critical(self, "Could not add", str(exc))
                return

        self.message.setText("Added to your wishlist.")
        self.on_change()
