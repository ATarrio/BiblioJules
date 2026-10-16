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

from ..services import library
from .db import session_scope
from .dialogs import StatusDialog
from .util import page_header

_STATUS_ID = Qt.ItemDataRole.UserRole


class StatusesView(QWidget):
    def __init__(self, on_change: Callable[[], None], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.on_change = on_change
        self._build_ui()

    def _build_ui(self) -> None:
        self.table = QTableWidget(0, 5)
        self.table.setHorizontalHeaderLabels(["", "Status", "Icon", "Type", "Description"])
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

        add_btn = QPushButton("＋  Add")
        add_btn.setProperty("variant", "primary")
        add_btn.clicked.connect(self._add)
        edit_btn = QPushButton("Edit")
        edit_btn.clicked.connect(self._edit)
        delete_btn = QPushButton("Delete")
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
                "Statuses",
                "Track where each book is: shelved, being read, lent out, or on the wishlist.",
            )
        )
        layout.addWidget(self.table, 1)
        layout.addLayout(actions)

    # -- data --------------------------------------------------------------- #
    def refresh(self) -> None:
        with session_scope() as db:
            statuses = library.list_statuses(db)
            rows = [
                (
                    status.id,
                    status.name,
                    status.icon or "",
                    "built-in" if status.is_system else "custom",
                    status.color or "#64748b",
                    status.description or "",
                )
                for status in statuses
            ]

        self.table.setRowCount(len(rows))
        for row_index, (status_id, name, icon, kind, color, description) in enumerate(rows):
            swatch = QTableWidgetItem("")
            swatch.setData(_STATUS_ID, status_id)
            self.table.setItem(row_index, 0, swatch)
            self.table.setCellWidget(row_index, 0, self._swatch(color))
            self.table.setItem(row_index, 1, QTableWidgetItem(name))
            self.table.setItem(row_index, 2, QTableWidgetItem(icon))
            self.table.setItem(row_index, 3, QTableWidgetItem(kind))
            self.table.setItem(row_index, 4, QTableWidgetItem(description))

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
            QMessageBox.information(self, "No selection", "Select a status first.")
        return status_id

    # -- actions ------------------------------------------------------------ #
    def _add(self) -> None:
        dialog = StatusDialog(self)
        if dialog.exec() != StatusDialog.DialogCode.Accepted:
            return
        try:
            with session_scope() as db:
                library.create_status(db, **dialog.data())
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Could not save", str(exc))
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
            with session_scope() as db:
                from ..models import Status

                status = db.get(Status, status_id)
                if status is None:
                    raise ValueError("This status no longer exists.")
                library.update_status(db, status, **dialog.data())
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Could not save", str(exc))
            return
        self.on_change()

    def _delete(self) -> None:
        status_id = self._require_selection()
        if status_id is None:
            return
        try:
            with session_scope() as db:
                from ..models import Status

                status = db.get(Status, status_id)
                if status is None:
                    raise ValueError("This status no longer exists.")
                if (
                    QMessageBox.question(
                        self, "Delete status", f"Delete the “{status.name}” status?"
                    )
                    != QMessageBox.StandardButton.Yes
                ):
                    return
                library.delete_status(db, status)
        except ValueError as exc:
            QMessageBox.warning(self, "Cannot delete", str(exc))
            return
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Could not delete", str(exc))
            return
        self.on_change()
