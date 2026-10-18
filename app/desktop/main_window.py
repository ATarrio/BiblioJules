"""Main application window: sidebar navigation over the individual views."""

from __future__ import annotations

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QAction
from PySide6.QtWidgets import (
    QComboBox,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QPushButton,
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
from .repo import AuthError, LocalRepo, RemoteRepo, RepoError, current_repo, set_repo
from .settings_dialog import SettingsDialog
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
        # Defer the first refresh so the sign-in prompt (if any) can appear
        # before any view asks the data source for rows.
        self._ready = False
        self._settings_open = False
        self._build_menu()
        self._build_ui()
        QTimer.singleShot(0, self._startup_check)

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

        # Which catalogue are we using? Clicking opens the settings dialog.
        self.connection_btn = QPushButton(self._connection_label())
        self.connection_btn.setObjectName("ConnectionButton")
        self.connection_btn.setFlat(True)
        self.connection_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self.connection_btn.setToolTip(_("Choose which library to use, and sign in."))
        self.connection_btn.clicked.connect(self._open_settings)
        connection_row = QWidget()
        connection_layout = QHBoxLayout(connection_row)
        connection_layout.setContentsMargins(14, 6, 14, 0)
        connection_layout.addWidget(self.connection_btn)

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
        sidebar_layout.addWidget(connection_row)
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

    def _rebuild(self) -> None:
        """Recreate the whole UI after a language or connection change."""
        current = self.stack.currentIndex() if hasattr(self, "stack") else 0
        self._ready = False
        self.menuBar().clear()
        self._build_menu()
        self._build_ui()
        if current > 0:
            self.nav.setCurrentRow(current)
        self._ready = True
        self.refresh_all()

    # -- connection --------------------------------------------------------- #
    def _connection_label(self) -> str:
        repo = current_repo()
        if isinstance(repo, RemoteRepo):
            if repo.token and not repo.token_rejected:
                account = preferences.get_account_name()
                return f"🌐  {account or repo.description}"
            return "🌐  " + _("Not signed in")
        return "💾  " + _("Local database")

    def _refresh_connection_label(self) -> None:
        if hasattr(self, "connection_btn"):
            self.connection_btn.setText(self._connection_label())

    def _open_settings(self) -> None:
        # Guarded: a failing refresh triggered from inside the dialog must not
        # stack a second copy of it on top.
        if self._settings_open:
            return
        self._settings_open = True
        try:
            dialog = SettingsDialog(self)
            if dialog.exec() != SettingsDialog.DialogCode.Accepted:
                return
            self._apply_settings(dialog.result_data())
        finally:
            self._settings_open = False

    def _apply_settings(self, data: dict) -> None:
        preferences.set_mode(data.get("mode") or preferences.MODE_LOCAL)
        preferences.set_remote_session(
            backend_url=data.get("backend_url") or "",
            token=data.get("token") or "",
            account=data.get("account") or "",
        )
        self._install_repo()
        self._rebuild()
        if preferences.get_mode() == preferences.MODE_REMOTE and not preferences.get_api_token():
            # Still no token: put the user back in the dialog rather than leave
            # them staring at empty views.
            QTimer.singleShot(0, self._open_settings)

    def _install_repo(self) -> None:
        previous = current_repo()
        if isinstance(previous, RemoteRepo):
            previous.close()
        if preferences.get_mode() == preferences.MODE_REMOTE:
            set_repo(RemoteRepo(preferences.get_backend_url(), preferences.get_api_token()))
        else:
            # Imported lazily so remote mode never opens the local SQLite file.
            from .db import initialize_database

            initialize_database()
            set_repo(LocalRepo())

    def _startup_check(self) -> None:
        repo = current_repo()
        if preferences.get_mode() == preferences.MODE_REMOTE and isinstance(repo, RemoteRepo):
            needs_sign_in = False
            if not repo.token:
                needs_sign_in = True
            else:
                try:
                    repo.verify()
                except AuthError:
                    needs_sign_in = True
                except RepoError as exc:
                    self.statusBar().showMessage(str(exc), 8000)
            if needs_sign_in:
                self._ready = True
                self._open_settings()
                # Signed in? Then show the catalogue. Cancelled? Leave the views
                # empty — the sidebar and status bar explain why.
                self.refresh_all()
                return
        self._ready = True
        self.refresh_all()

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
        if self._ready:
            self._safe_refresh(self._views[row])

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
                self._safe_refresh(view)

    def _safe_refresh(self, view) -> None:
        """Refresh a view, turning data-source failures into a message.

        We deliberately do *not* pop the settings dialog here: a signed-out
        session would otherwise greet the user with one dialog per view. The
        status bar says what to do, and the sidebar button is one click away.
        """
        try:
            view.refresh()
        except AuthError as exc:
            self.statusBar().showMessage(str(exc), 15000)
            self._refresh_connection_label()
        except RepoError as exc:
            self.statusBar().showMessage(str(exc), 8000)

    # -- menu --------------------------------------------------------------- #
    def _build_menu(self) -> None:
        file_menu = self.menuBar().addMenu(_("&File"))
        settings_action = QAction(_("&Settings…"), self)
        settings_action.setShortcut("Ctrl+,")
        settings_action.triggered.connect(self._open_settings)
        file_menu.addAction(settings_action)
        file_menu.addSeparator()
        quit_action = QAction(_("&Quit"), self)
        quit_action.setShortcut("Ctrl+Q")
        quit_action.triggered.connect(self.close)
        file_menu.addAction(quit_action)

        help_menu = self.menuBar().addMenu(_("&Help"))
        about_action = QAction(_("&About"), self)
        about_action.triggered.connect(self._about)
        help_menu.addAction(about_action)

    def _about(self) -> None:
        if preferences.get_mode() == preferences.MODE_REMOTE:
            where = _(
                "Connected to the hosted library at <b>%s</b>."
                % (preferences.get_backend_url() or _("(no URL set)"))
            )
        else:
            where = _("Using the SQLite database on this computer, shared with the web app.")
        QMessageBox.about(
            self,
            _("About %(app)s") % {"app": settings.app_name},
            _(
                "<b>%(app)s</b><br>%(description)s<br><br>"
                "Desktop edition.<br>%(where)s"
            )
            % {
                "app": settings.app_name,
                "description": _("A catalog for your home library."),
                "where": where,
            },
        )
