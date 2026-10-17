"""Catalog view: filterable table of books with add/edit/lend/return actions."""

from __future__ import annotations

from typing import Callable

from PySide6.QtCore import Qt
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (
    QAbstractItemView,
    QComboBox,
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
from ..services.serializers import book_to_dict
from .db import session_scope
from .util import card, fill_combo, location_choices, page_header, status_choices
from .dialogs import BookDetailsDialog, BookDialog, LendDialog

_SORTS = [("recent", "Newest first"), ("title", "Title"), ("author", "Author"), ("year", "Year")]
_LOANED = [(None, "Any"), ("loaned", "On loan"), ("available", "Available")]


class CatalogView(QWidget):
    def __init__(self, on_change: Callable[[], None], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.on_change = on_change
        self._build_ui()

    # -- construction ------------------------------------------------------- #
    def _build_ui(self) -> None:
        self.search = QLineEdit()
        self.search.setPlaceholderText("Search title, author, publisher, ISBN…")
        self.search.returnPressed.connect(self.reload_books)

        self.status = QComboBox()
        self.location = QComboBox()

        self.loaned = QComboBox()
        for value, label in _LOANED:
            self.loaned.addItem(label, value)

        self.sort = QComboBox()
        for value, label in _SORTS:
            self.sort.addItem(label, value)

        refresh_btn = QPushButton("Refresh")
        refresh_btn.setProperty("variant", "ghost")
        refresh_btn.clicked.connect(self.refresh)

        filter_card = card()
        filter_row = QHBoxLayout(filter_card)
        filter_row.setContentsMargins(14, 12, 14, 12)
        filter_row.setSpacing(10)
        filter_row.addWidget(self.search, 2)
        filter_row.addWidget(self.status, 1)
        filter_row.addWidget(self.location, 1)
        filter_row.addWidget(self.loaned)
        filter_row.addWidget(self.sort)
        filter_row.addWidget(refresh_btn)

        self.table = QTableWidget(0, 6)
        self.table.setHorizontalHeaderLabels(
            ["Title", "Author(s)", "Status", "Location", "Year", "Loan"]
        )
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setAlternatingRowColors(True)
        self.table.setShowGrid(False)
        self.table.verticalHeader().setVisible(False)
        self.table.verticalHeader().setDefaultSectionSize(38)
        header = self.table.horizontalHeader()
        header.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        header.setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(3, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(4, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(5, QHeaderView.ResizeMode.ResizeToContents)
        self.table.itemDoubleClicked.connect(lambda *_: self._details())

        add_btn = QPushButton("＋  Add book")
        add_btn.setProperty("variant", "primary")
        add_btn.clicked.connect(self._add)
        edit_btn = QPushButton("Edit")
        edit_btn.clicked.connect(self._edit)
        details_btn = QPushButton("Details")
        details_btn.clicked.connect(self._details)
        lend_btn = QPushButton("Lend")
        lend_btn.clicked.connect(self._lend)
        return_btn = QPushButton("Return")
        return_btn.clicked.connect(self._return)
        delete_btn = QPushButton("Delete")
        delete_btn.setProperty("variant", "danger")
        delete_btn.clicked.connect(self._delete)

        actions = QHBoxLayout()
        actions.setSpacing(8)
        actions.addWidget(add_btn)
        actions.addWidget(edit_btn)
        actions.addWidget(details_btn)
        actions.addWidget(lend_btn)
        actions.addWidget(return_btn)
        actions.addStretch(1)
        actions.addWidget(delete_btn)

        self.summary = QLabel("")
        self.summary.setObjectName("Dim")

        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 24, 28, 24)
        layout.setSpacing(16)
        layout.addWidget(page_header("Catalog", "Scan a book or search your shelves."))
        layout.addWidget(filter_card)
        layout.addWidget(self.summary)
        layout.addWidget(self.table, 1)
        layout.addLayout(actions)

    # -- data --------------------------------------------------------------- #
    def refresh(self) -> None:
        self._reload_choices()
        self.reload_books()

    def _reload_choices(self) -> None:
        current_status = self.status.currentData()
        current_location = self.location.currentData()
        with session_scope() as db:
            statuses = status_choices(db)
            locations = location_choices(db)
        fill_combo(self.status, statuses, none_label="All statuses", current=current_status)
        fill_combo(self.location, locations, none_label="All locations", current=current_location)

    def reload_books(self) -> None:
        with session_scope() as db:
            rows = [
                book_to_dict(book)
                for book in library.query_books(
                    db,
                    search=self.search.text().strip() or None,
                    status_id=self.status.currentData(),
                    location_id=self.location.currentData(),
                    loaned=self.loaned.currentData(),
                    sort=self.sort.currentData() or "recent",
                )
            ]

        self.table.setRowCount(len(rows))
        self.summary.setText(f"{len(rows)} book{'s' if len(rows) != 1 else ''}")
        for row_index, row in enumerate(rows):
            status = row.get("status") or {}
            loan = row.get("active_loan")
            if loan:
                loan_text = f"→ {loan['borrower_name']}"
                if loan.get("is_overdue"):
                    loan_text += "  (overdue)"
            else:
                loan_text = ""

            values = [
                row["title"],
                ", ".join(row.get("authors") or []) or "Unknown author",
                status.get("name") or "",
                (row.get("location") or {}).get("full_path") or "",
                str(row.get("published_year") or ""),
                loan_text,
            ]
            for column, text in enumerate(values):
                item = QTableWidgetItem(text)
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, row["id"])
                if column == 2 and status.get("color"):
                    item.setForeground(QColor(status["color"]))
                self.table.setItem(row_index, column, item)

    # -- helpers ------------------------------------------------------------ #
    def _selected_id(self) -> int | None:
        row = self.table.currentRow()
        if row < 0:
            return None
        item = self.table.item(row, 0)
        return item.data(Qt.ItemDataRole.UserRole) if item else None

    def _require_selection(self) -> int | None:
        book_id = self._selected_id()
        if book_id is None:
            QMessageBox.information(self, "No selection", "Select a book first.")
        return book_id

    # -- actions ------------------------------------------------------------ #
    def _add(self) -> None:
        dialog = BookDialog(self)
        if dialog.exec() != BookDialog.DialogCode.Accepted:
            return
        try:
            with session_scope() as db:
                library.create_book(db, dialog.data())
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Could not save", str(exc))
            return
        self.on_change()

    def _edit(self) -> None:
        book_id = self._require_selection()
        if book_id is None:
            return
        dialog = BookDialog(self, book_id=book_id)
        if dialog.exec() != BookDialog.DialogCode.Accepted:
            return
        try:
            with session_scope() as db:
                book = library.get_book(db, book_id)
                if book is None:
                    raise ValueError("This book no longer exists.")
                library.update_book(db, book, dialog.data())
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Could not save", str(exc))
            return
        self.on_change()

    def _details(self) -> None:
        book_id = self._require_selection()
        if book_id is None:
            return
        BookDetailsDialog(self, book_id=book_id, on_change=self.on_change).exec()

    def _lend(self) -> None:
        book_id = self._require_selection()
        if book_id is None:
            return
        with session_scope() as db:
            book = library.get_book(db, book_id)
            if book is None:
                QMessageBox.warning(self, "Not found", "This book no longer exists.")
                return
            title = book.title
            if book.active_loan is not None:
                QMessageBox.information(self, "Already on loan", "This book is already lent out.")
                return

        dialog = LendDialog(self, book_title=title)
        if dialog.exec() != LendDialog.DialogCode.Accepted:
            return
        payload = dialog.data()
        try:
            with session_scope() as db:
                book = library.get_book(db, book_id)
                library.lend_book(db, book, **payload)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Could not lend", str(exc))
            return
        self.on_change()

    def _return(self) -> None:
        book_id = self._require_selection()
        if book_id is None:
            return
        with session_scope() as db:
            book = library.get_book(db, book_id)
            if book is None or book.active_loan is None:
                QMessageBox.information(self, "Not on loan", "This book is not currently lent out.")
                return
            borrower = book.active_loan.borrower_name
        if (
            QMessageBox.question(
                self, "Return book", f"Mark the book as returned by {borrower}?"
            )
            != QMessageBox.StandardButton.Yes
        ):
            return
        try:
            with session_scope() as db:
                book = library.get_book(db, book_id)
                library.return_loan(db, book)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Could not return", str(exc))
            return
        self.on_change()

    def _delete(self) -> None:
        book_id = self._require_selection()
        if book_id is None:
            return
        with session_scope() as db:
            book = library.get_book(db, book_id)
            title = book.title if book else "this book"
        if (
            QMessageBox.question(
                self, "Delete book", f"Permanently delete “{title}” and its loan history?"
            )
            != QMessageBox.StandardButton.Yes
        ):
            return
        try:
            with session_scope() as db:
                book = library.get_book(db, book_id)
                if book is not None:
                    library.delete_book(db, book)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Could not delete", str(exc))
            return
        self.on_change()
