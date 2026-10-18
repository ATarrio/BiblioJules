"""Statuses view: manage the user-editable status list."""

from __future__ import annotations

from typing import Callable

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QAbstractItemView,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QMessageBox,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from .. import i18n
from ..i18n import _
from .repo import get_repo
from .dialogs import StatusDialog
from .util import ColumnSort, page_header

_STATUS_ID = Qt.ItemDataRole.UserRole


class StatusesView(QWidget):
    def __init__(self, on_change: Callable[[], None], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.on_change = on_change
        self._build_ui()

    def _build_ui(self) -> None:
        self.table = QTableWidget(0, 5)
        self.table.setHorizontalHeaderLabels(
            ["", _("Status"), _("Icon"), _("Type"), _("Description")]
        )
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setAlternatingRowColors(True)
        self.table.setShowGrid(False)
        self.table.verticalHeader().setVisible(False)
        self.table.verticalHeader().setDefaultSectionSize(40)
        self.table.setColumnWidth(0, 28)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(4, QHeaderView.ResizeMode.Stretch)
        self.table.itemDoubleClicked.connect(lambda *_: self._edit())

        # Clicking a column header orders the rows (again to flip the direction).
        self._rows: list[dict] = []
        self._sort = ColumnSort(
            self.table,
            {
                0: lambda row: row["name"].casefold(),
                1: lambda row: row["name"].casefold(),
                2: lambda row: row["icon"].casefold(),
                3: lambda row: row["kind"].casefold(),
                4: lambda row: row["description"].casefold(),
            },
            self._render_rows,
        )

        add_btn = QPushButton("＋  " + _("Add"))
        add_btn.setProperty("variant", "primary")
        add_btn.clicked.connect(self._add)
        edit_btn = QPushButton(_("Edit"))
        edit_btn.clicked.connect(self._edit)
        delete_btn = QPushButton(_("Delete"))
        delete_btn.setProperty("variant", "danger")
        delete_btn.clicked.connect(self._delete)

        actions = QHBoxLayout()
        actions.setSpacing(8)
        actions.addWidget(add_btn)
        actions.addWidget(edit_btn)
        actions.addStretch(1)
        actions.addWidget(delete_btn)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 24, 28, 24)
        layout.setSpacing(16)
        layout.addWidget(
            page_header(
                _("Statuses"),
                _("Track where each book is: shelved, being read, lent out, or on the wishlist."),
            )
        )
        layout.addWidget(self.table, 1)
        layout.addLayout(actions)

    # -- data --------------------------------------------------------------- #
    def refresh(self) -> None:
        self._rows = [
            {
                "id": status.get("id"),
                "name": i18n.status_label_from(status.get("slug"), status.get("name")),
                "icon": status.get("icon") or "",
                "kind": _("built-in") if status.get("is_system") else _("custom"),
                "color": status.get("color") or "#64748b",
                "description": status.get("description") or "",
            }
            for status in get_repo().list_statuses()
        ]
        self._render_rows()

    def _render_rows(self) -> None:
        rows = self._sort.apply(self._rows)
        self.table.setRowCount(0)
        self.table.setRowCount(len(rows))
        for row_index, row in enumerate(rows):
            swatch = QTableWidgetItem("")
            swatch.setData(_STATUS_ID, row["id"])
            self.table.setItem(row_index, 0, swatch)
            self.table.setCellWidget(row_index, 0, self._swatch(row["color"]))
            self.table.setItem(row_index, 1, QTableWidgetItem(row["name"]))
            self.table.setItem(row_index, 2, QTableWidgetItem(row["icon"]))
            self.table.setItem(row_index, 3, QTableWidgetItem(row["kind"]))
            self.table.setItem(row_index, 4, QTableWidgetItem(row["description"]))

    @staticmethod
    def _swatch(color: str) -> QWidget:
        """A centred coloured dot shown in the first column."""
        holder = QWidget()
        holder.setStyleSheet("background: transparent;")
        layout = QHBoxLayout(holder)
        layout.setContentsMargins(0, 0, 0, 0)
        dot = QLabel()
        dot.setFixedSize(12, 12)
        dot.setStyleSheet(f"background-color: {color}; border-radius: 6px;")
        layout.addWidget(dot, 0, Qt.AlignmentFlag.AlignCenter)
        return holder

    def _selected_id(self) -> int | None:
        row = self.table.currentRow()
        if row < 0:
            return None
        item = self.table.item(row, 0)
        return item.data(_STATUS_ID) if item else None

    def _require_selection(self) -> int | None:
        status_id = self._selected_id()
        if status_id is None:
            QMessageBox.information(self, _("No selection"), _("Select a status first."))
        return status_id

    # -- actions ------------------------------------------------------------ #
    def _add(self) -> None:
        dialog = StatusDialog(self)
        if dialog.exec() != StatusDialog.DialogCode.Accepted:
            return
        try:
            get_repo().create_status(dialog.data())
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not save"), str(exc))
            return
        self.on_change()

    def _edit(self) -> None:
        status_id = self._require_selection()
        if status_id is None:
            return
        dialog = StatusDialog(self, status_id=status_id)
        if dialog.exec() != StatusDialog.DialogCode.Accepted:
            return
        try:
            get_repo().update_status(status_id, dialog.data())
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not save"), str(exc))
            return
        self.on_change()

    def _delete(self) -> None:
        status_id = self._require_selection()
        if status_id is None:
            return
        try:
            status = get_repo().get_status(status_id)
            if status is None:
                raise ValueError(_("This status no longer exists."))
            if status.get("is_system"):
                QMessageBox.warning(
                    self, _("Cannot delete"), _("System statuses cannot be deleted.")
                )
                return
            if (
                QMessageBox.question(
                    self,
                    _("Delete status"),
                    _("Delete the “%s” status?") % (status.get("name") or ""),
                )
                != QMessageBox.StandardButton.Yes
            ):
                return
            get_repo().delete_status(status_id)
        except ValueError as exc:
            QMessageBox.warning(self, _("Cannot delete"), str(exc))
            return
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not delete"), str(exc))
            return
        self.on_change()
