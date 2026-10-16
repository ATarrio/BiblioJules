"""Main application window: sidebar navigation over the individual views."""

from __future__ import annotations

from PySide6.QtCore import QTimer, Qt
from PySide6.QtGui import QAction
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from ..config import settings
from .catalog import CatalogView
from .dashboard import DashboardView
from .discover import DiscoverView
from .locations_view import LocationsView
from .statuses_view import StatusesView

# (emoji, label, view) — order mirrors the web app's sidebar.
_PAGES = [
    ("🏠", "Dashboard"),
    ("📚", "Catalog"),
    ("🔍", "Discover"),
    ("📍", "Locations"),
    ("🏷️", "Statuses"),
]


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle(settings.app_name)
        self.resize(1240, 800)

        # --- sidebar ----------------------------------------------------- #
        sidebar = QWidget()
        sidebar.setObjectName("Sidebar")
        sidebar.setFixedWidth(232)

        brand = QWidget()
        brand_layout = QHBoxLayout(brand)
        brand_layout.setContentsMargins(20, 18, 20, 12)
        brand_layout.setSpacing(8)
        emoji_label = QLabel("📚")
        emoji_label.setObjectName("BrandEmoji")
        title_label = QLabel(settings.app_name)
        title_label.setObjectName("BrandTitle")
        brand_layout.addWidget(emoji_label)
        brand_layout.addWidget(title_label)
        brand_layout.addStretch(1)

        self.nav = QListWidget()
        self.nav.setObjectName("NavList")
        self.nav.setFrameShape(QListWidget.Shape.NoFrame)
        for emoji, label in _PAGES:
            self.nav.addItem(QListWidgetItem(f"{emoji}   {label}"))

        sidebar_layout = QVBoxLayout(sidebar)
        sidebar_layout.setContentsMargins(0, 0, 0, 0)
        sidebar_layout.setSpacing(0)
        sidebar_layout.addWidget(brand)
        sidebar_layout.addWidget(self.nav, 1)
        sidebar_layout.addSpacing(12)

        # --- views ------------------------------------------------------- #
        self.stack = QStackedWidget()
        self.dashboard = DashboardView()
        self.catalog = CatalogView(self.notify_change)
        self.discover = DiscoverView(self.notify_change)
        self.locations = LocationsView(self.notify_change)
        self.statuses = StatusesView(self.notify_change)
        for view in (self.dashboard, self.catalog, self.discover, self.locations, self.statuses):
            self.stack.addWidget(view)
        self._views = [self.dashboard, self.catalog, self.discover, self.locations, self.statuses]

        central = QWidget()
        layout = QHBoxLayout(central)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        layout.addWidget(sidebar)
        layout.addWidget(self.stack, 1)
        self.setCentralWidget(central)

        self.nav.currentRowChanged.connect(self._on_nav_changed)
        self.nav.setCurrentRow(0)
        self._build_menu()
        self.refresh_all()

    # -- behaviour ---------------------------------------------------------- #
    def _on_nav_changed(self, row: int) -> None:
        if row < 0:
            return
        self.stack.setCurrentIndex(row)
        self._views[row].refresh()

    def notify_change(self) -> None:
        """Called by views after they mutate data.

        Deferred so the originating widget can finish its event handler before
        every view (including itself) is rebuilt.
        """
        QTimer.singleShot(0, self.refresh_all)

    def refresh_all(self) -> None:
        current = self.stack.currentIndex()
        for row, view in enumerate(self._views):
            # Reload the visible view immediately; the rest lazily on navigation.
            if row == current:
                view.refresh()

    # -- menu --------------------------------------------------------------- #
    def _build_menu(self) -> None:
        file_menu = self.menuBar().addMenu("&File")
        quit_action = QAction("&Quit", self)
        quit_action.setShortcut("Ctrl+Q")
        quit_action.triggered.connect(self.close)
        file_menu.addAction(quit_action)

        help_menu = self.menuBar().addMenu("&Help")
        about_action = QAction("&About", self)
        about_action.triggered.connect(self._about)
        help_menu.addAction(about_action)

    def _about(self) -> None:
        QMessageBox.about(
            self,
            f"About {settings.app_name}",
            f"<b>{settings.app_name}</b><br>{settings.app_description}<br><br>"
            "Desktop edition — shares its SQLite database with the web app.",
        )
