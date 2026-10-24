"""Want-to-read list: books to look for next, kept outside the catalogue."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Callable

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QAbstractItemView,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from ..i18n import _
from .repo import RemoteRepo, get_repo
from .util import card, page_header
from .workers import run_blocking

_WANT_ID = Qt.ItemDataRole.UserRole


class WantlistView(QWidget):
    def __init__(self, on_change: Callable[[], None] | None = None, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.on_change = on_change
        self._rows: list[dict] = []
        self._loading = False
        self._deleted = False
        self.destroyed.connect(self._mark_deleted)
        self._build_ui()

    def _mark_deleted(self, *_: object) -> None:
        self._deleted = True

    def _build_ui(self) -> None:
        self.title = QLineEdit()
        self.title.setPlaceholderText(_("Title"))
        self.authors = QLineEdit()
        self.authors.setPlaceholderText(_("Authors"))
        add_btn = QPushButton(_("Add to want-to-read"))
        add_btn.setProperty("variant", "primary")
        add_btn.clicked.connect(self._add)
        self.add_btn = add_btn

        add_card = card()
        add_row = QHBoxLayout(add_card)
        add_row.setContentsMargins(14, 12, 14, 12)
        add_row.setSpacing(10)
        add_row.addWidget(self.title, 2)
        add_row.addWidget(self.authors, 2)
        add_row.addWidget(add_btn)

        self.message = QLabel("")
        self.message.setObjectName("Hint")
        self.message.setWordWrap(True)
        self.message.setVisible(False)

        self.table = QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels([_("Title"), _("Authors"), _("ISBN")])
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setAlternatingRowColors(True)
        self.table.setShowGrid(False)
        self.table.verticalHeader().setVisible(False)
        self.table.verticalHeader().setDefaultSectionSize(38)
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)

        self.empty = QLabel(_("Nothing on your want-to-read list yet."))
        self.empty.setObjectName("Muted")
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)

        move_btn = QPushButton(_("Move to catalog"))
        move_btn.setProperty("variant", "primary")
        move_btn.clicked.connect(self._move)
        remove_btn = QPushButton(_("Remove selected"))
        remove_btn.setProperty("variant", "danger")
        remove_btn.clicked.connect(self._remove)
        actions = QHBoxLayout()
        actions.addStretch(1)
        actions.addWidget(move_btn)
        actions.addWidget(remove_btn)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 24, 28, 24)
        layout.setSpacing(16)
        layout.addWidget(
            page_header(
                _("Want-to-read list"),
                _(
                    "Books you want to read next. Stored on this device only, "
                    "even when your library is shared."
                ),
            )
        )
        layout.addWidget(add_card)
        layout.addWidget(self.message)
        layout.addWidget(self.table, 1)
        layout.addWidget(self.empty)
        layout.addLayout(actions)

    # -- data --------------------------------------------------------------- #
    @staticmethod
    def _fetch() -> list[dict]:
        return get_repo().want_list()

    def refresh(self) -> None:
        if self._loading:
            return
        if isinstance(get_repo(), RemoteRepo):
            self._loading = True
            run_blocking(self._fetch, self._apply, self._load_failed)
            return
        self._apply(self._fetch())

    def _load_failed(self, message: str) -> None:
        self._loading = False
        if self._deleted:
            return
        self._show_error(_("Could not load the want-to-read list: %s") % message)

    def _apply(self, rows: list[dict]) -> None:
        self._loading = False
        if self._deleted:
            return
        self._rows = [row for row in rows if isinstance(row, dict)]
        self.table.setRowCount(len(self._rows))
        for index, row in enumerate(self._rows):
            title = QTableWidgetItem(str(row.get("title") or ""))
            title.setData(_WANT_ID, row.get("id") or row.get("isbn") or row.get("title"))
            authors = row.get("authors")
            if isinstance(authors, list):
                authors = ", ".join(str(name) for name in authors)
            self.table.setItem(index, 0, title)
            self.table.setItem(index, 1, QTableWidgetItem(str(authors or "")))
            self.table.setItem(index, 2, QTableWidgetItem(str(row.get("isbn") or "")))
        self.empty.setVisible(not self._rows)
        self.table.setVisible(bool(self._rows))
        self.message.setVisible(False)

    def _show_error(self, message: str) -> None:
        self.message.setText(message)
        self.message.setVisible(True)

    # -- actions ------------------------------------------------------------ #
    def _add(self) -> None:
        title = self.title.text().strip()
        if not title:
            self._show_error(_("Enter a title first."))
            return
        entry = {
            "id": f"want-{uuid.uuid4().hex}",
            "isbn": None,
            "title": title,
            "authors": self.authors.text().strip(),
            "publisher": None,
            "notes": "",
            "added_at": datetime.now(timezone.utc).isoformat(),
        }
        self.add_btn.setEnabled(False)
        if isinstance(get_repo(), RemoteRepo):
            run_blocking(
                lambda: get_repo().add_want(entry),
                lambda _result: self._added(),
                self._action_failed,
            )
            return
        try:
            get_repo().add_want(entry)
        except Exception as exc:  # noqa: BLE001
            self._action_failed(str(exc))
            return
        self._added()

    def _added(self) -> None:
        self.add_btn.setEnabled(True)
        if self._deleted:
            return
        self.title.clear()
        self.authors.clear()
        self.refresh()

    def _remove(self) -> None:
        row = self.table.currentRow()
        if row < 0:
            self._show_error(_("Select an entry first."))
            return
        item = self.table.item(row, 0)
        entry_id = item.data(_WANT_ID) if item else None
        if not entry_id:
            return
        if isinstance(get_repo(), RemoteRepo):
            run_blocking(
                lambda: get_repo().remove_want(str(entry_id)),
                lambda _result: self.refresh(),
                self._action_failed,
            )
            return
        try:
            get_repo().remove_want(str(entry_id))
        except Exception as exc:  # noqa: BLE001
            self._action_failed(str(exc))
            return
        self.refresh()

    def _move(self) -> None:
        row = self.table.currentRow()
        if row < 0:
            self._show_error(_("Select an entry first."))
            return
        item = self.table.item(row, 0)
        entry_id = item.data(_WANT_ID) if item else None
        if not entry_id:
            return
        entry = self._rows[row] if 0 <= row < len(self._rows) else {}
        title = str(entry.get("title") or "")
        authors = entry.get("authors")
        if isinstance(authors, list):
            authors = ", ".join(str(a) for a in authors)
        if isinstance(get_repo(), RemoteRepo):
            run_blocking(
                lambda: _move_entry(entry, get_repo()),
                lambda _result: self.refresh(),
                self._action_failed,
            )
            return
        try:
            _move_entry(entry, get_repo())
        except Exception as exc:  # noqa: BLE001
            self._action_failed(str(exc))
            return
        self.refresh()


def _move_entry(entry: dict, repo) -> None:
    """Create a book from a want-to-read entry with 'to_read' status."""
    isbn = entry.get("isbn") or None
    repo.create_book({
        "isbn": isbn,
        "title": entry.get("title", ""),
        "authors": entry.get("authors", ""),
        "publisher": entry.get("publisher"),
        "read_status": "to_read",
        "source": "want_list_import",
    })
    repo.remove_want(str(entry.get("id", "")))


def _action_failed(self, message: str) -> None:
        self.add_btn.setEnabled(True)
        if self._deleted:
            return
        self._show_error(_("Could not update the want-to-read list: %s") % message)
