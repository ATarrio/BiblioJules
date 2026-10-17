"""Main application window: sidebar navigation over the individual views."""

from __future__ import annotations

from PySide6.QtCore import QTimer
from PySide6.QtGui import QAction
from PySide6.QtWidgets import (
    QComboBox,
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

from .. import i18n, preferences
from ..config import settings
from ..i18n import _
from .catalog import CatalogView
from .dashboard import DashboardView
from .discover import DiscoverView
from .locations_view import LocationsView
from .statuses_view import StatusesView

# (emoji, English source label) — order mirrors the web app's sidebar.
# Labels are translated when the UI is built, so a language switch can rebuild it.
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
        self._build_menu()
        self._build_ui()

    # -- construction ------------------------------------------------------- #
    def _build_ui(self) -> None:
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
        for emoji, source in _PAGES:
            self.nav.addItem(QListWidgetItem(f"{emoji}   {_(source)}"))

        # Language selector, pinned to the bottom of the sidebar.
        self.language = QComboBox()
        for code, name in i18n.SUPPORTED_LANGUAGES.items():
            self.language.addItem(f"🌐  {name}", code)
        index = self.language.findData(i18n.get_language())
        if index >= 0:
            self.language.setCurrentIndex(index)
        self.language.currentIndexChanged.connect(self._on_language_changed)
        language_row = QWidget()
        language_layout = QHBoxLayout(language_row)
        language_layout.setContentsMargins(14, 6, 14, 14)
        language_layout.addWidget(self.language)

        sidebar_layout = QVBoxLayout(sidebar)
        sidebar_layout.setContentsMargins(0, 0, 0, 0)
        sidebar_layout.setSpacing(0)
        sidebar_layout.addWidget(brand)
        sidebar_layout.addWidget(self.nav, 1)
        sidebar_layout.addWidget(language_row)

        # --- views ------------------------------------------------------- #
        self.stack = QStackedWidget()
        self.dashboard = DashboardView(self.notify_change)
        self.catalog = CatalogView(self.notify_change)
        self.discover = DiscoverView(self.notify_change)
        self.locations = LocationsView(self.notify_change)
        self.statuses = StatusesView(self.notify_change)
        self._views = [self.dashboard, self.catalog, self.discover, self.locations, self.statuses]
        for view in self._views:
            self.stack.addWidget(view)

        central = QWidget()
        layout = QHBoxLayout(central)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        layout.addWidget(sidebar)
        layout.addWidget(self.stack, 1)
        self.setCentralWidget(central)

        self.nav.currentRowChanged.connect(self._on_nav_changed)
        self.nav.setCurrentRow(0)
        self.refresh_all()

    def _rebuild(self) -> None:
        """Recreate the whole UI after a language change."""
        current = self.stack.currentIndex() if hasattr(self, "stack") else 0
        self.menuBar().clear()
        self._build_menu()
        self._build_ui()
        if current > 0:
            self.nav.setCurrentRow(current)

    # -- language ----------------------------------------------------------- #
    def _on_language_changed(self, index: int) -> None:
        code = self.language.itemData(index)
        if not code or code == i18n.get_language():
            return
        i18n.set_language(code)
        preferences.set_preferred_language(code)
        # Defer: this combo lives inside the widget we are about to replace, so
        # let the signal handler return before its parent is destroyed.
        QTimer.singleShot(0, self._rebuild)

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
        file_menu = self.menuBar().addMenu(_("&File"))
        quit_action = QAction(_("&Quit"), self)
        quit_action.setShortcut("Ctrl+Q")
        quit_action.triggered.connect(self.close)
        file_menu.addAction(quit_action)

        help_menu = self.menuBar().addMenu(_("&Help"))
        about_action = QAction(_("&About"), self)
        about_action.triggered.connect(self._about)
        help_menu.addAction(about_action)

    def _about(self) -> None:
        QMessageBox.about(
            self,
            _("About %(app)s") % {"app": settings.app_name},
            _(
                "<b>%(app)s</b><br>%(description)s<br><br>"
                "Desktop edition — shares its SQLite database with the web app."
            )
            % {"app": settings.app_name, "description": _("A catalog for your home library.")},
        )
