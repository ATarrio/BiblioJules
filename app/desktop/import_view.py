"""Import a Goodreads/StoryGraph CSV into the library or the want-to-read list."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QAbstractItemView,
    QFileDialog,
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
from ..services.import_service import parse_import_csv
from .repo import RemoteRepo, get_repo
from .util import card, page_header
from .workers import run_blocking

MAX_CSV_BYTES = 20 * 1024 * 1024
MAX_IMPORT_ROWS = 5000
_ROW = Qt.ItemDataRole.UserRole


class ImportView(QWidget):
    def __init__(self, on_change: Callable[[], None], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.on_change = on_change
        self._rows: list[dict] = []
        self._deleted = False
        self.destroyed.connect(self._mark_deleted)
        self._build_ui()

    def _mark_deleted(self, *_: object) -> None:
        self._deleted = True

    def _build_ui(self) -> None:
        self.path = QLineEdit()
        self.path.setReadOnly(True)
        self.path.setPlaceholderText(_("Choose a CSV file…"))
        browse = QPushButton(_("Browse…"))
        browse.clicked.connect(self._browse)
        preview_btn = QPushButton(_("Preview"))
        preview_btn.clicked.connect(self._preview)
        self.preview_btn = preview_btn

        file_card = card()
        file_row = QHBoxLayout(file_card)
        file_row.setContentsMargins(14, 12, 14, 12)
        file_row.setSpacing(10)
        file_row.addWidget(self.path, 1)
        file_row.addWidget(browse)
        file_row.addWidget(preview_btn)

        self.message = QLabel(
            _("Goodreads, StoryGraph, or any CSV with ISBN, title and author columns.")
        )
        self.message.setObjectName("Hint")
        self.message.setWordWrap(True)

        self.table = QTableWidget(0, 5)
        self.table.setHorizontalHeaderLabels(
            ["", _("Title"), _("Authors"), _("ISBN"), _("Read status")]
        )
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setAlternatingRowColors(True)
        self.table.setShowGrid(False)
        self.table.verticalHeader().setVisible(False)
        self.table.verticalHeader().setDefaultSectionSize(38)
        self.table.setColumnWidth(0, 28)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(3, QHeaderView.ResizeMode.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(4, QHeaderView.ResizeMode.ResizeToContents)

        select_all = QPushButton(_("Select all"))
        select_all.clicked.connect(lambda: self._set_all_checked(True))
        clear_btn = QPushButton(_("Clear selection"))
        clear_btn.clicked.connect(lambda: self._set_all_checked(False))
        self.import_btn = QPushButton(_("Import selected"))
        self.import_btn.setProperty("variant", "primary")
        self.import_btn.clicked.connect(self._import)
        actions = QHBoxLayout()
        actions.setSpacing(8)
        actions.addWidget(select_all)
        actions.addWidget(clear_btn)
        actions.addStretch(1)
        actions.addWidget(self.import_btn)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 24, 28, 24)
        layout.setSpacing(16)
        layout.addWidget(
            page_header(
                _("Import a CSV"),
                _("Bulk-add books from Goodreads, StoryGraph or any CSV export."),
            )
        )
        layout.addWidget(file_card)
        layout.addWidget(self.message)
        layout.addWidget(self.table, 1)
        layout.addLayout(actions)

    def refresh(self) -> None:
        # The preview is transient; nothing to reload from the database.
        pass

    # -- file / preview ----------------------------------------------------- #
    def _browse(self) -> None:
        name, _filter = QFileDialog.getOpenFileName(
            self, _("Choose a CSV file"), "", _("CSV files (*.csv);;All files (*)")
        )
        if not name:
            return
        self.path.setText(name)
        self._load_file(Path(name))

    def _preview(self) -> None:
        text = self.path.text().strip()
        if not text:
            self._browse()
            return
        self._load_file(Path(text))

    def _load_file(self, path: Path) -> None:
        try:
            if path.stat().st_size > MAX_CSV_BYTES:
                raise ValueError(_("That file is too large (the limit is 20 MB)."))
            content = path.read_bytes()
        except OSError as exc:
            self._show_message(_("Could not read %(name)s: %(error)s") % {"name": path.name, "error": exc}, error=True)
            return
        except ValueError as exc:
            self._show_message(str(exc), error=True)
            return

        try:
            rows = parse_import_csv(content.decode("utf-8-sig", errors="replace"))
        except Exception as exc:  # noqa: BLE001 - a malformed CSV is a user error
            self._show_message(_("Could not read that CSV: %s") % exc, error=True)
            return
        if not rows:
            self._show_message(_("No rows found in that CSV."), error=True)
            return
        if len(rows) > MAX_IMPORT_ROWS:
            self._show_message(
                _("That CSV has too many rows (the limit is %(count)s).")
                % {"count": MAX_IMPORT_ROWS},
                error=True,
            )
            return

        self._rows = [dict(row, _selected=True) for row in rows]
        self._render_rows()
        self._show_message(
            _("%(count)s row(s) ready. Clear the tick beside any row you do not want.")
            % {"count": len(rows)}
        )

    def _render_rows(self) -> None:
        self.table.setRowCount(len(self._rows))
        for index, row in enumerate(self._rows):
            check = QTableWidgetItem("")
            check.setFlags(
                Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsUserCheckable
            )
            check.setCheckState(
                Qt.CheckState.Checked if row.get("_selected", True) else Qt.CheckState.Unchecked
            )
            check.setData(_ROW, row)
            self.table.setItem(index, 0, check)
            title = str(row.get("title") or "").strip() or _("(untitled)")
            authors = row.get("authors") or ""
            if isinstance(authors, list):
                authors = ", ".join(str(name) for name in authors)
            self.table.setItem(index, 1, QTableWidgetItem(title))
            self.table.setItem(index, 2, QTableWidgetItem(str(authors)))
            self.table.setItem(index, 3, QTableWidgetItem(str(row.get("isbn") or "")))
            self.table.setItem(
                index, 4, QTableWidgetItem(str(row.get("read_status") or ""))
            )

    def _set_all_checked(self, checked: bool) -> None:
        state = Qt.CheckState.Checked if checked else Qt.CheckState.Unchecked
        for index, row in enumerate(self._rows):
            row["_selected"] = checked
            item = self.table.item(index, 0)
            if item is not None:
                item.setCheckState(state)

    def _selected_rows(self) -> list[dict]:
        selected: list[dict] = []
        for index, row in enumerate(self._rows):
            item = self.table.item(index, 0)
            row["_selected"] = bool(item and item.checkState() == Qt.CheckState.Checked)
            if row["_selected"]:
                selected.append(row)
        return selected

    # -- import ------------------------------------------------------------- #
    def _import(self) -> None:
        rows = self._selected_rows()
        if not rows:
            self._show_message(_("Select at least one row first."), error=True)
            return
        self.import_btn.setEnabled(False)
        self.preview_btn.setEnabled(False)
        self._show_message(_("Importing…"))
        if isinstance(get_repo(), RemoteRepo):
            run_blocking(
                _run_import,
                lambda result: self._import_done(result, len(rows)),
                self._import_failed,
                rows,
            )
            return
        try:
            result = _run_import(rows)
        except Exception as exc:  # noqa: BLE001
            self._import_failed(str(exc))
            return
        self._import_done(result, len(rows))

    def _import_done(self, result: dict, attempted: int) -> None:
        self.import_btn.setEnabled(True)
        self.preview_btn.setEnabled(True)
        if self._deleted:
            return
        text = _(
            "Imported %(imported)s book(s), skipped %(skipped)s duplicate(s), "
            "and added %(want)s to the want-to-read list."
        ) % {
            "imported": result.get("imported", 0),
            "skipped": result.get("skipped", 0),
            "want": result.get("want", 0),
        }
        errors = result.get("errors") or []
        if errors:
            text += "\n" + _("Some rows failed: %s") % "; ".join(errors[:3])
        self._show_message(text, error=bool(errors))
        if attempted:
            self.on_change()

    def _import_failed(self, message: str) -> None:
        self.import_btn.setEnabled(True)
        self.preview_btn.setEnabled(True)
        if not self._deleted:
            self._show_message(_("Could not import: %s") % message, error=True)

    def _show_message(self, text: str, *, error: bool = False) -> None:
        self.message.setText(text)
        self.message.setStyleSheet("color: #dc2626;" if error else "")
        self.message.setVisible(True)


def _run_import(rows: list[dict]) -> dict:
    """Create books (or want-list entries) without touching any widgets."""
    repo = get_repo()
    want_titles = {
        (item.get("title") or "").strip().casefold()
        for item in repo.want_list()
        if isinstance(item, dict)
    }
    imported = 0
    skipped = 0
    want = 0
    errors: list[str] = []
    for row in rows:
        title = str(row.get("title") or "").strip() or "Untitled"
        authors = row.get("authors") or ""
        isbn = str(row.get("isbn") or "").strip() or None
        try:
            if not isbn:
                key = title.casefold()
                if key in want_titles:
                    skipped += 1
                    continue
                repo.add_want(
                    {
                        "id": f"want-{uuid.uuid4().hex}",
                        "isbn": None,
                        "title": title,
                        "authors": authors,
                        "publisher": row.get("publisher"),
                        "notes": "",
                        "added_at": datetime.now(timezone.utc).isoformat(),
                    }
                )
                want_titles.add(key)
                want += 1
                continue
            if repo.find_by_isbn(isbn):
                skipped += 1
                continue
            repo.create_book(
                {
                    "isbn": isbn,
                    "title": title,
                    "authors": authors,
                    "publisher": row.get("publisher"),
                    "published_date": str(row.get("published_year") or "") or None,
                    "page_count": row.get("page_count"),
                    "language": row.get("language"),
                    "cover_url": row.get("cover_url"),
                    "description": row.get("description"),
                    "score": row.get("score"),
                    "read_status": row.get("read_status"),
                    "source": "csv_import",
                }
            )
            imported += 1
        except Exception as exc:  # noqa: BLE001 - report the row, keep going
            errors.append(f"{title}: {exc}")
    return {"imported": imported, "skipped": skipped, "want": want, "errors": errors}
