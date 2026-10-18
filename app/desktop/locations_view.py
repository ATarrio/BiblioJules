"""Locations view: manage the hierarchical shelf/room tree."""

from __future__ import annotations

from typing import Callable

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QAbstractItemView,
    QHBoxLayout,
    QHeaderView,
    QMessageBox,
    QPushButton,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
    QWidget,
)

from ..i18n import _
from .repo import get_repo
from .dialogs import LocationDialog
from .util import page_header

_LOC_ID = Qt.ItemDataRole.UserRole


class LocationsView(QWidget):
    def __init__(self, on_change: Callable[[], None], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.on_change = on_change
        self._build_ui()

    def _build_ui(self) -> None:
        self.tree = QTreeWidget()
        self.tree.setColumnCount(3)
        self.tree.setHeaderLabels([_("Location"), _("Kind"), _("Description")])
        self.tree.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.tree.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.tree.setAlternatingRowColors(True)
        self.tree.setColumnWidth(1, 120)
        self.tree.header().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.tree.header().setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        self.tree.itemDoubleClicked.connect(lambda *_: self._edit())

        add_btn = QPushButton("＋  " + _("Add"))
        add_btn.setProperty("variant", "primary")
        add_btn.clicked.connect(self._add)
        add_child_btn = QPushButton(_("Add child"))
        add_child_btn.clicked.connect(self._add_child)
        edit_btn = QPushButton(_("Edit"))
        edit_btn.clicked.connect(self._edit)
        delete_btn = QPushButton(_("Delete"))
        delete_btn.setProperty("variant", "danger")
        delete_btn.clicked.connect(self._delete)

        actions = QHBoxLayout()
        actions.setSpacing(8)
        actions.addWidget(add_btn)
        actions.addWidget(add_child_btn)
        actions.addWidget(edit_btn)
        actions.addStretch(1)
        actions.addWidget(delete_btn)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 24, 28, 24)
        layout.setSpacing(16)
        layout.addWidget(
            page_header(
                _("Locations"),
                _("Rooms, shelves and boxes. Nest them however your home is arranged."),
            )
        )
        layout.addWidget(self.tree, 1)
        layout.addLayout(actions)

    # -- data --------------------------------------------------------------- #
    def refresh(self) -> None:
        rows = [
            (
                loc.get("id"),
                loc.get("parent_id"),
                loc.get("name") or "",
                loc.get("kind") or "",
                loc.get("description") or "",
            )
            for loc in get_repo().list_locations()
        ]

        self.tree.clear()
        items: dict[int, QTreeWidgetItem] = {}
        for loc_id, parent_id, name, kind, description in rows:
            item = QTreeWidgetItem([name, kind, description])
            item.setData(0, _LOC_ID, loc_id)
            items[loc_id] = item
            parent = items.get(parent_id)
            if parent is None:
                self.tree.addTopLevelItem(item)
            else:
                parent.addChild(item)
                parent.setExpanded(True)

    def _selected_id(self) -> int | None:
        item = self.tree.currentItem()
        return item.data(0, _LOC_ID) if item is not None else None

    # -- actions ------------------------------------------------------------ #
    def _add(self) -> None:
        dialog = LocationDialog(self)
        if dialog.exec() != LocationDialog.DialogCode.Accepted:
            return
        try:
            get_repo().create_location(dialog.data())
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not save"), str(exc))
            return
        self.on_change()

    def _add_child(self) -> None:
        parent_id = self._selected_id()
        if parent_id is None:
            QMessageBox.information(
                self, _("No selection"), _("Select a parent location first.")
            )
            return
        dialog = LocationDialog(self, preselect_parent=parent_id)
        if dialog.exec() != LocationDialog.DialogCode.Accepted:
            return
        try:
            get_repo().create_location(dialog.data())
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not save"), str(exc))
            return
        self.on_change()

    def _edit(self) -> None:
        location_id = self._selected_id()
        if location_id is None:
            QMessageBox.information(self, _("No selection"), _("Select a location first."))
            return
        dialog = LocationDialog(self, location_id=location_id)
        if dialog.exec() != LocationDialog.DialogCode.Accepted:
            return
        try:
            get_repo().update_location(location_id, dialog.data())
        except ValueError as exc:
            QMessageBox.warning(self, _("Could not move"), str(exc))
            return
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not save"), str(exc))
            return
        self.on_change()

    def _delete(self) -> None:
        location_id = self._selected_id()
        if location_id is None:
            QMessageBox.information(self, _("No selection"), _("Select a location first."))
            return
        try:
            location = get_repo().get_location(location_id)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not load"), str(exc))
            return
        name = (location or {}).get("name") or _("this location")
        if (
            QMessageBox.question(
                self,
                _("Delete location"),
                _("Delete “%s” and everything nested inside it? "
                  "Books are kept but lose this location.") % name,
            )
            != QMessageBox.StandardButton.Yes
        ):
            return
        try:
            get_repo().delete_location(location_id)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, _("Could not delete"), str(exc))
            return
        self.on_change()
