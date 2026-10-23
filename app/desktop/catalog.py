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

from .. import i18n
from ..book_fields import READ_STATUSES
from ..i18n import _
from .repo import RemoteRepo, get_repo
from .util import (
    ColumnSort,
    card,
    fill_combo,
    location_choices,
    page_header,
    read_status_label,
    score_label,
    status_choices,
)
from .dialogs import BookDetailsDialog, BookDialog, LendDialog
from .workers import run_blocking

# (value, English source label); translated when the combo is built.
_SORTS = [
    ("recent", "Newest first"),
    ("title", "Title"),
    ("author", "Author"),
    ("year", "Year"),
    ("saga", "Saga"),
]
_LOANED = [(None, "Any"), ("loaned", "On loan"), ("available", "Available")]


class CatalogView(QWidget):
    def __init__(self, on_change: Callable[[], None], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.on_change = on_change
        self._seq = 0
        self._deleted = False
        self.destroyed.connect(self._mark_deleted)
        self._build_ui()

    # -- construction ------------------------------------------------------- #
    def _build_ui(self) -> None:
        self.search = QLineEdit()
        self.search.setPlaceholderText(_("Search title, author, publisher, ISBN…"))
        self.search.returnPressed.connect(self.reload_books)

        self.status = QComboBox()
        self.location = QComboBox()
        self.saga = QComboBox()
        self.read_status = QComboBox()

        self.loaned = QComboBox()
        for value, label in _LOANED:
            self.loaned.addItem(_(label), value)

        self.sort = QComboBox()
        for value, label in _SORTS:
            self.sort.addItem(_(label), value)

        refresh_btn = QPushButton(_("Refresh"))
        refresh_btn.setProperty("variant", "ghost")
        refresh_btn.clicked.connect(self.refresh)

        filter_card = card()
        # Two rows so the filters stay readable at the default window size.
        filter_layout = QVBoxLayout(filter_card)
        filter_layout.setContentsMargins(14, 12, 14, 12)
        filter_layout.setSpacing(10)

        top_row = QHBoxLayout()
        top_row.setSpacing(10)
        top_row.addWidget(self.search, 2)
        top_row.addWidget(self.status, 1)
        top_row.addWidget(self.location, 1)
        top_row.addWidget(self.saga, 1)

        bottom_row = QHBoxLayout()
        bottom_row.setSpacing(10)
        bottom_row.addWidget(self.read_status)
        bottom_row.addWidget(self.loaned)
        bottom_row.addWidget(self.sort)
        bottom_row.addWidget(refresh_btn)
        bottom_row.addStretch(1)

        filter_layout.addLayout(top_row)
        filter_layout.addLayout(bottom_row)

        self.table = QTableWidget(0, 9)
        self.table.setHorizontalHeaderLabels(
            [
                _("Title"),
                _("Author(s)"),
                _("Saga"),
                _("Read status"),
                _("Score"),
                _("Status"),
                _("Location"),
                _("Year"),
                _("Loan"),
            ]
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
        for column in range(1, 9):
            header.setSectionResizeMode(column, QHeaderView.ResizeMode.ResizeToContents)
        self.table.itemDoubleClicked.connect(lambda *_: self._details())

        # Clicking a column header orders the rows (again to flip ascending/descending).
        self._rows: list[dict] = []
        self._sort = ColumnSort(
            self.table,
            {
                0: lambda row: (row["title"] or "").casefold(),
                1: lambda row: ", ".join(row.get("authors") or []).casefold(),
                2: lambda row: self._saga_text(row).casefold(),
                3: lambda row: (read_status_label(row.get("read_status")) or "").casefold(),
                4: lambda row: (row.get("score") is None, row.get("score") or 0),
                5: lambda row: self._status_text(row).casefold(),
                6: lambda row: ((row.get("location") or {}).get("full_path") or "").casefold(),
                7: lambda row: (
                    row.get("published_year") is None,
                    row.get("published_year") or 0,
                ),
                8: lambda row: self._loan_text(row).casefold(),
            },
            self._render_rows,
        )

        add_btn = QPushButton("＋  " + _("Add book"))
        add_btn.setProperty("variant", "primary")
        add_btn.clicked.connect(self._add)
        edit_btn = QPushButton(_("Edit"))
        edit_btn.clicked.connect(self._edit)
        details_btn = QPushButton(_("Details"))
        details_btn.clicked.connect(self._details)
        lend_btn = QPushButton(_("Lend"))
        lend_btn.clicked.connect(self._lend)
        return_btn = QPushButton(_("Return"))
        return_btn.clicked.connect(self._return)
        delete_btn = QPushButton(_("Delete"))
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
        layout.addWidget(page_header(_("Catalog"), _("Scan a book or search your shelves.")))
        layout.addWidget(filter_card)
        layout.addWidget(self.summary)
        layout.addWidget(self.table, 1)
        layout.addLayout(actions)

        # Changing a filter (or the "order by" combo) refreshes the list at once.
        self.status.currentIndexChanged.connect(self.reload_books)
        self.location.currentIndexChanged.connect(self.reload_books)
        self.saga.currentIndexChanged.connect(self.reload_books)
        self.read_status.currentIndexChanged.connect(self.reload_books)
        self.loaned.currentIndexChanged.connect(self.reload_books)
        self.sort.currentIndexChanged.connect(self._on_sort_changed)

    def _on_sort_changed(self, *_: object) -> None:
        # The combo sets the base order; hand sorting back to it.
        self._sort.clear()
        self.reload_books()

    # -- data --------------------------------------------------------------- #
    def _mark_deleted(self, *_: object) -> None:
        self._deleted = True

    def refresh(self) -> None:
        if isinstance(get_repo(), RemoteRepo):
            self._request(reload_choices=True)
            return
        self._reload_choices()
        self.reload_books()

    def _reload_choices(self) -> None:
        current = self._current_choices()
        repo = get_repo()
        self._apply_choices(
            repo.list_statuses(), repo.list_locations(), repo.sagas(), current
        )

    def _current_choices(self) -> tuple:
        return (
            self.status.currentData(),
            self.location.currentData(),
            self.saga.currentData(),
            self.read_status.currentData(),
        )

    def _apply_choices(self, statuses, locations, sagas, current: tuple) -> None:
        current_status, current_location, current_saga, current_read_status = current
        fill_combo(self.status, status_choices(statuses), none_label=_("All statuses"), current=current_status)
        fill_combo(
            self.location, location_choices(locations), none_label=_("All locations"), current=current_location
        )
        fill_combo(
            self.saga,
            [(name, name) for name in sagas],
            none_label=_("All sagas"),
            current=current_saga,
        )
        fill_combo(
            self.read_status,
            [(slug, read_status_label(slug)) for slug, _label in READ_STATUSES],
            none_label=_("All read statuses"),
            current=current_read_status,
        )

    def _filters(self) -> dict:
        return {
            "search": self.search.text().strip() or None,
            "status_id": self.status.currentData(),
            "location_id": self.location.currentData(),
            "saga": self.saga.currentData(),
            "read_status": self.read_status.currentData(),
            "loaned": self.loaned.currentData(),
            "sort": self.sort.currentData() or "recent",
        }

    def _request(self, *, reload_choices: bool) -> None:
        """Fetch remote rows off the GUI thread, ignoring stale replies."""
        repo = get_repo()
        self._seq += 1
        seq = self._seq
        filters = self._filters()
        current = self._current_choices()

        def fetch():
            choices = None
            if reload_choices:
                choices = (repo.list_statuses(), repo.list_locations(), repo.sagas())
            return choices, repo.list_books(**filters)

        run_blocking(
            fetch,
            lambda data: self._apply_remote(seq, data, current, reload_choices),
            lambda message: self._load_failed(seq, message),
        )

    def _apply_remote(self, seq: int, data: tuple, current: tuple, reload_choices: bool) -> None:
        if self._deleted or seq != self._seq:
            return
        choices, rows = data
        if reload_choices and choices is not None:
            self._apply_choices(*choices, current)
        self._rows = rows
        self._render_rows()

    def _load_failed(self, seq: int, message: str) -> None:
        if self._deleted or seq != self._seq:
            return
        self.summary.setText(_("Could not load: %s") % message)

    def reload_books(self, *_: object) -> None:
        if isinstance(get_repo(), RemoteRepo):
            self._request(reload_choices=False)
            return
        self._rows = get_repo().list_books(**self._filters())
        self._render_rows()

    @staticmethod
    def _saga_text(row: dict) -> str:
        saga = row.get("saga")
        if not saga:
            return ""
        number = row.get("saga_number")
        return f"{saga} #{number}" if number else saga

    @staticmethod
    def _status_text(row: dict) -> str:
        status = row.get("status") or {}
        return i18n.status_label_from(status.get("slug"), status.get("name"))

    @staticmethod
    def _loan_text(row: dict) -> str:
        loan = row.get("active_loan")
        if not loan:
            return ""
        text = _("→ %s") % loan["borrower_name"]
        if loan.get("is_overdue"):
            text += _("  (overdue)")
        return text

    def _render_rows(self) -> None:
        rows = self._sort.apply(self._rows)
        self.table.setRowCount(len(rows))
        count = len(rows)
        self.summary.setText(i18n.ngettext("%d book", "%d books", count) % count)
        for row_index, row in enumerate(rows):
            status = row.get("status") or {}
            values = [
                row["title"],
                ", ".join(row.get("authors") or []) or _("Unknown author"),
                self._saga_text(row),
                read_status_label(row.get("read_status")),
                score_label(row.get("score")),
                self._status_text(row),
                (row.get("location") or {}).get("full_path") or "",
                str(row.get("published_year") or ""),
                self._loan_text(row),
            ]
            for column, text in enumerate(values):
                item = QTableWidgetItem(text)
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, row["id"])
                if column == 5 and status.get("color"):
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
            QMessageBox.information(self, _("No selection"), _("Select a book first."))
        return book_id

    # -- actions ------------------------------------------------------------ #
    def _fetch(self, book_id: int) -> dict | None:
        """Load one book for an action, reporting any problem to the user."""
        try:
            book = get_repo().get_book(book_id)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not load"), str(exc))
            return None
        if book is None:
            QMessageBox.warning(self, _("Not found"), _("This book no longer exists."))
            return None
        return book

    def _add(self) -> None:
        dialog = BookDialog(self, on_bulk_save=self._bulk_create)
        if dialog.exec() != BookDialog.DialogCode.Accepted:
            return
        try:
            get_repo().create_book(dialog.data())
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not save"), str(exc))
            return
        self.on_change()

    def _bulk_create(self, payload: dict) -> str | None:
        """Persist one book from a keep-open add. Returns an error message or None."""
        try:
            get_repo().create_book(payload)
        except Exception as exc:  # noqa: BLE001
            return str(exc)
        self.on_change()
        return None

    def _edit(self) -> None:
        book_id = self._require_selection()
        if book_id is None:
            return
        dialog = BookDialog(self, book_id=book_id)
        if dialog.exec() != BookDialog.DialogCode.Accepted:
            return
        try:
            get_repo().update_book(book_id, dialog.data())
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not save"), str(exc))
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
        book = self._fetch(book_id)
        if book is None:
            return
        if book.get("active_loan") is not None:
            QMessageBox.information(
                self, _("Already on loan"), _("This book is already lent out.")
            )
            return

        dialog = LendDialog(self, book_title=book.get("title") or "")
        if dialog.exec() != LendDialog.DialogCode.Accepted:
            return
        try:
            get_repo().lend_book(book_id, dialog.data())
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not lend"), str(exc))
            return
        self.on_change()

    def _return(self) -> None:
        book_id = self._require_selection()
        if book_id is None:
            return
        book = self._fetch(book_id)
        if book is None:
            return
        loan = book.get("active_loan")
        if not loan:
            QMessageBox.information(
                self, _("Not on loan"), _("This book is not currently lent out.")
            )
            return
        if (
            QMessageBox.question(
                self,
                _("Return book"),
                _("Mark the book as returned by %s?") % (loan.get("borrower_name") or ""),
            )
            != QMessageBox.StandardButton.Yes
        ):
            return
        try:
            get_repo().return_book(book_id)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not return"), str(exc))
            return
        self.on_change()

    def _delete(self) -> None:
        book_id = self._require_selection()
        if book_id is None:
            return
        book = self._fetch(book_id)
        if book is None:
            return
        if (
            QMessageBox.question(
                self,
                _("Delete book"),
                _("Permanently delete “%s” and its loan history?")
                % (book.get("title") or _("this book")),
            )
            != QMessageBox.StandardButton.Yes
        ):
            return
        try:
            get_repo().delete_book(book_id)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not delete"), str(exc))
            return
        self.on_change()
